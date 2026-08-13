"""Pathfinder API — news scraping service.

This is the first slice of the backend described in `backend/docs/API_ENDPOINTS.md`:
the news endpoints and the daily scraper that fills them. Everything else in
that document (auth, case intake, compliance, chat, evidence) is still spec.

Auth is deliberately absent here: `/api/news/*` serves public policy updates
matched to a *node id*, not to a person, so there is nothing user-scoped to
protect yet. Per-user alert state (`applied_to_tracker`, dismissals) arrives
with the user table, and those endpoints will require a session.

Run it:
    cd backend
    pip install -r requirements.txt
    uvicorn app.main:app --reload --port 8000
"""

from __future__ import annotations

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware

from .intake import MODEL as INTAKE_MODEL
from .intake import IntakeResolver
from .models import (
    IntakeRequest,
    IntakeResult,
    IntakeStatus,
    NewsFeed,
    ScrapeReport,
    SourceInfo,
)
from .scraper import Scraper
from .store import NewsStore

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("pathfinder.api")

SCRAPE_INTERVAL = timedelta(hours=24)
SCRAPE_ON_STARTUP = os.getenv("SCRAPE_ON_STARTUP", "1") == "1"

store = NewsStore()
scraper = Scraper()
intake_resolver = IntakeResolver()

#: Intake is the one LLM-backed endpoint here and it is unauthenticated, so it
#: gets a cheap per-IP fixed window (PROJECT_PRD §4 asks for a rate limit on
#: exactly this set). A dict is enough for a single-process demo service; when
#: this moves behind a session it becomes a per-user limit in the store.
INTAKE_LIMIT = int(os.getenv("INTAKE_RATE_LIMIT", "12"))
INTAKE_WINDOW = timedelta(minutes=10)
_intake_hits: dict[str, list[datetime]] = {}


def _rate_limit_intake(client_ip: str) -> None:
    now = datetime.now(timezone.utc)
    cutoff = now - INTAKE_WINDOW
    hits = [t for t in _intake_hits.get(client_ip, []) if t > cutoff]
    if len(hits) >= INTAKE_LIMIT:
        raise HTTPException(
            status_code=429,
            detail=(
                f"Too many intake requests. The limit is {INTAKE_LIMIT} per "
                f"{int(INTAKE_WINDOW.total_seconds() // 60)} minutes."
            ),
        )
    hits.append(now)
    _intake_hits[client_ip] = hits
    # Drop the tails of everyone who has gone quiet, so the dict can't grow
    # without bound on a long-lived process.
    if len(_intake_hits) > 5000:
        for ip in [k for k, v in _intake_hits.items() if not any(t > cutoff for t in v)]:
            del _intake_hits[ip]

#: Guards against two scrapes overlapping — the scheduled one and a manual
#: refresh, most likely.
_scrape_lock = asyncio.Lock()


async def run_scrape() -> ScrapeReport:
    async with _scrape_lock:
        items, report = await scraper.run()
        report.items_new = store.save_items(items)
        store.save_run(report)
        log.info(
            "scrape complete: %s found, %s new, %s sources failed",
            report.items_found,
            report.items_new,
            len(report.sources_failed),
        )
        return report


async def _daily_loop() -> None:
    """Scrape once a day for the lifetime of the process.

    In-process rather than a cron service, so a single Render web service is
    enough to run the demo. For production, swap this for a Render Cron Job
    hitting `POST /api/news/refresh` — the work is identical and a cron job
    survives the web process being recycled.
    """
    if SCRAPE_ON_STARTUP and store.is_stale():
        try:
            await run_scrape()
        except Exception:  # noqa: BLE001
            log.exception("startup scrape failed")

    while True:
        await asyncio.sleep(SCRAPE_INTERVAL.total_seconds())
        try:
            await run_scrape()
        except Exception:  # noqa: BLE001
            # A failed run must never kill the loop, or the feed silently
            # freezes at whatever it last held.
            log.exception("scheduled scrape failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(_daily_loop())
    yield
    task.cancel()


app = FastAPI(
    title="Pathfinder API",
    version="0.1.0",
    summary="Immigration pathway and compliance tracker — news slice",
    lifespan=lifespan,
)

# The Flutter web build is served from a different origin in every environment
# (localhost during dev, a Render static site in prod). These endpoints are
# public, read-only policy data, so a permissive read origin is appropriate;
# tighten this the moment a user-scoped endpoint lands here.
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("CORS_ORIGINS", "*").split(","),
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


@app.get("/api/health")
async def health() -> dict[str, object]:
    run = store.last_run()
    return {
        "status": "ok",
        "last_scrape": run.finished_at if run else None,
        "stale": store.is_stale(),
    }


@app.get("/api/news/alerts", response_model=NewsFeed)
async def alerts(
    node: str | None = Query(
        default=None,
        description="Pathway node id, e.g. student.stem_opt — returns only "
        "updates matched to that status.",
    ),
    source: str | None = Query(default=None, description="Filter to one source id."),
    days: int | None = Query(
        default=None,
        ge=1,
        le=365,
        description="Only items first seen in the last N days.",
    ),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> NewsFeed:
    since = (
        datetime.now(timezone.utc) - timedelta(days=days) if days is not None else None
    )
    items, total = store.items(
        node_id=node, source_id=source, since=since, limit=limit, offset=offset
    )
    run = store.last_run()
    return NewsFeed(
        items=items,
        total=total,
        last_scraped_at=run.finished_at if run else None,
        stale=store.is_stale(),
    )


@app.get("/api/news/sources", response_model=list[SourceInfo])
async def sources() -> list[SourceInfo]:
    """The allow-list, with each source's last result.

    Public on purpose: "show your work" is a product requirement, not a debug
    endpoint (PROJECT_PRD §8.2).
    """
    return store.source_info()


@app.get("/api/news/status", response_model=ScrapeReport | None)
async def status() -> ScrapeReport | None:
    return store.last_run()


@app.get("/api/case/intake/status", response_model=IntakeStatus)
async def intake_status() -> IntakeStatus:
    """Whether the reasoner is configured.

    The client asks before offering the free-text path, so it can lead with its
    own questionnaire rather than inviting someone to describe their life to an
    endpoint that will only keyword-match it.
    """
    graph = intake_resolver.graph
    return IntakeStatus(
        llm_available=intake_resolver.llm_available,
        model=INTAKE_MODEL if intake_resolver.llm_available else None,
        node_count=len(graph.nodes),
        graph_as_of=graph.as_of,
    )


@app.post("/api/case/intake", response_model=IntakeResult)
async def intake(body: IntakeRequest, request: Request) -> IntakeResult:
    """Free text in → a *proposed* current status and goal out.

    Public for now for the same reason the news endpoints are: it reads nothing
    and writes nothing. The moment this result is persisted against a person it
    moves behind a session, exactly as `backend/docs/API_ENDPOINTS.md` §3
    describes — the response shape does not change when it does.
    """
    _rate_limit_intake(request.client.host if request.client else "unknown")
    return await intake_resolver.resolve(body)


@app.post("/api/news/refresh", response_model=ScrapeReport)
async def refresh() -> ScrapeReport:
    """Scrape now.

    This is both the manual refresh button and the endpoint a Render Cron Job
    should hit if you move scheduling out of the process.
    """
    if _scrape_lock.locked():
        raise HTTPException(status_code=409, detail="A scrape is already running.")
    return await run_scrape()
