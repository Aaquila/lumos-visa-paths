"""Lumos API — news scraping service.

This is the first slice of the backend described in `backend/docs/API_ENDPOINTS.md`:
the news endpoints and the daily scraper that fills them. Everything else in
that document (case intake persistence, compliance, chat, evidence) is still
spec.

Two things about identity here, both deliberate:

* **Tokens are verified, not trusted.** A caller may present a Google ID token.
  If they do, it is verified properly — RS256 signature against Google's JWKS,
  `aud` equal to the configured client id, a Google `iss`, and an unexpired
  `exp` — and a bad one is a 401 rather than a shrug. Endpoints that read a
  person's own situation use `optional_caller`, so they work signed-out and are
  never fooled by a forged header.
* **Nothing about a caller is stored.** There is no user table, no session
  table, and no row anywhere keyed by a person. Verification is stateless: the
  claim is used for the length of the request and dropped. Tokens, emails and
  free-text situations are never logged.

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
from pathlib import Path

from dotenv import load_dotenv

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session

from .intake import MODEL as INTAKE_MODEL
from .intake import IntakeResolver
from .models import (
    AllNewsFeedResponse,
    IntakeRequest,
    IntakeResult,
    IntakeStatus,
    MarkReadResponse,
    NewsFeed,
    PathwayOptionSet,
    PersonalisedNewsFeed,
    RelevantNewsItem,
    ScrapeReport,
    SituationInput,
    SourceInfo,
    UnreadNewsFeedResponse,
    UserNewsArticle,
)
from .options import GOALS, build_option_set
from .personalization import personalize_articles
from .relevance import DISCLAIMER as RELEVANCE_DISCLAIMER
from .relevance import RelevanceScorer, counts
from .scheduler import scheduler, register_scraper_job
from .scraper import Scraper
from .store import NewsStore
from .summarizer import PersonalizedSummarizer
from .database import init_db, get_db, User, UserVisaSituation, NewsArticle, UserNews, UserPreferences

# Load .env from the repo root before any os.getenv calls.
_env_path = Path(__file__).parent.parent.parent / '.env'
if _env_path.exists():
    load_dotenv(_env_path)

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("lumos.api")

SCRAPE_INTERVAL = timedelta(hours=24)
SCRAPE_ON_STARTUP = os.getenv("SCRAPE_ON_STARTUP", "1") == "1"

# Server configuration from .env.
BACKEND_HOST = os.getenv("BACKEND_HOST", "127.0.0.1").strip()
BACKEND_PORT = int(os.getenv("BACKEND_PORT", "8000"))

store = NewsStore()
scraper = Scraper()
intake_resolver = IntakeResolver()
relevance_scorer = RelevanceScorer()
personalized_summarizer = PersonalizedSummarizer()


# ── Google ID token verification ──────────────────────────────────────────────
#
# Stateless by construction. There is no user table and no session table, and
# adding one is the change this file exists to prevent: the product's stated
# position is that the backend stores nothing about the person. We verify the
# token, use the `sub` claim for the length of the request, and drop it.

#: Never hardcoded. A Google *web* client id is public (it ships in the JS
#: bundle) but it is still environment configuration, and hardcoding it would
#: mean a second deployment silently accepted the first deployment's tokens.
#: Read GOOGLE_AUTH_CLIENT_ID first (new name), fall back to GOOGLE_CLIENT_ID
#: for compatibility.
GOOGLE_CLIENT_ID = (
    os.getenv("GOOGLE_AUTH_CLIENT_ID") or os.getenv("GOOGLE_CLIENT_ID", "")
).strip()

#: Client secret: reserved for future server-side OAuth flows (e.g. refresh
#: token exchange). Google's ID-token verification uses only the client ID.
#: Do not use elsewhere without understanding the security model.
GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_AUTH_CLIENT_SECRET", "").strip()

GOOGLE_JWKS_URL = os.getenv(
    "GOOGLE_JWKS_URL", "https://www.googleapis.com/oauth2/v3/certs"
)

#: Google signs with both spellings and has done for years. Both are legitimate;
#: anything else is not.
GOOGLE_ISSUERS = frozenset({"accounts.google.com", "https://accounts.google.com"})

#: Google's keys rotate; PyJWKClient caches them and refetches on an unknown
#: `kid`, so this is built once and reused.
_jwk_client: object | None = None


def _jwks_client():
    global _jwk_client
    if _jwk_client is None:
        _jwk_client = jwt.PyJWKClient(GOOGLE_JWKS_URL, cache_keys=True)
    return _jwk_client


def _signing_key(token: str):
    """Google's public key for this token, by `kid`.

    Split out as its own function so tests can substitute a local key pair
    instead of reaching Google — the verification logic under test is the same
    either way.
    """
    return _jwks_client().get_signing_key_from_jwt(token).key


def verify_google_id_token(token: str) -> str:
    """Verify a Google ID token and return its `sub`, or raise 401.

    Checks, in order: the signature against Google's published keys, `aud`
    against our configured client id, `iss` against Google's two issuer
    spellings, and `exp`/`iat`. A token missing any of those claims is rejected
    rather than accepted with a default.

    Only `sub` is returned. The email and name in a Google token are real
    personal data and this service has no use for them, so they are not read,
    not returned and not logged.
    """
    if not GOOGLE_CLIENT_ID:
        # Refusing is the safe failure: accepting unverifiable tokens because
        # the server is misconfigured is how "we verify tokens" becomes false.
        raise HTTPException(
            status_code=503,
            detail=(
                "This server has no GOOGLE_CLIENT_ID configured, so it cannot "
                "verify ID tokens. Send the request without an Authorization "
                "header, or configure the server."
            ),
        )

    try:
        claims = jwt.decode(
            token,
            _signing_key(token),
            algorithms=["RS256"],
            audience=GOOGLE_CLIENT_ID,
            options={
                "require": ["exp", "iat", "aud", "iss", "sub"],
                "verify_signature": True,
                "verify_exp": True,
                "verify_aud": True,
            },
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=401, detail="That Google ID token has expired. Sign in again."
        ) from None
    except jwt.InvalidAudienceError:
        raise HTTPException(
            status_code=401,
            detail="That Google ID token was issued for a different application.",
        ) from None
    except Exception:  # noqa: BLE001 — bad signature, malformed, unknown kid
        # Deliberately not including the exception text or the token: an error
        # message is a log line waiting to happen.
        raise HTTPException(
            status_code=401, detail="That Google ID token could not be verified."
        ) from None

    if claims.get("iss") not in GOOGLE_ISSUERS:
        raise HTTPException(
            status_code=401, detail="That ID token was not issued by Google."
        )

    subject = claims.get("sub")
    if not subject:
        raise HTTPException(status_code=401, detail="That ID token carries no subject.")
    return str(subject)


async def optional_caller(
    authorization: str | None = Header(default=None),
) -> str | None:
    """Verified-if-present authentication.

    No header → `None`, and the endpoint serves the request anyway; the news
    feed is genuinely public and gating it would be theatre. A header that *is*
    present is verified strictly, so a forged or expired token is a 401 rather
    than something quietly trusted.

    The return value is an opaque Google subject id and is used for nothing but
    proving the caller is who they say. It is never persisted or logged.
    """
    if authorization is None:
        return None

    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(
            status_code=401,
            detail="Authorization must be 'Bearer <google-id-token>'.",
        )
    return verify_google_id_token(token.strip())


async def required_user(
    authorization: str | None = Header(default=None),
    db: Session = Depends(get_db),
) -> User:
    """Verify token and return the authenticated user.

    Unlike optional_caller, this requires a valid token and that the user
    exists in the database. Returns a User model or raises 401.
    """
    if authorization is None:
        raise HTTPException(
            status_code=401,
            detail="Authorization header required.",
        )

    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(
            status_code=401,
            detail="Authorization must be 'Bearer <google-id-token>'.",
        )

    subject = verify_google_id_token(token.strip())

    # Look up user by Google subject claim
    user = db.query(User).filter(User.sub == subject).first()
    if user is None:
        raise HTTPException(
            status_code=401,
            detail="User not yet registered",
        )
    return user

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

        # Run personalization job after scrape
        try:
            if report.items_new > 0:
                personalization_stats = await personalize_articles(
                    relevance_scorer, personalized_summarizer
                )
                log.info(
                    "personalization complete: processed %d users, evaluated %d articles, "
                    "created %d matches",
                    personalization_stats["users_processed"],
                    personalization_stats["articles_evaluated"],
                    personalization_stats["matches_created"],
                )
            else:
                log.info("personalization: skipped (no new articles)")
        except Exception as e:  # noqa: BLE001
            log.exception("personalization failed: %s", e)

        return report


@asynccontextmanager
async def lifespan(app: FastAPI):
    """App startup and shutdown with APScheduler integration.

    On startup:
    1. Initialize the database with all required tables
    2. Register the scraper job with APScheduler (weekdays 12 PM & 6 PM PT)
    3. Run an immediate scrape if configured and data is stale
    4. Start the scheduler

    On shutdown:
    1. Stop the scheduler gracefully
    """
    # Initialize the database with all required tables.
    init_db()
    log.info("Database initialized")

    # Register scraper job with APScheduler for weekdays at 12 PM and 6 PM PT.
    register_scraper_job(run_scrape)
    log.info("Scraper started")

    # Run a scrape on startup if configured and data is stale.
    if SCRAPE_ON_STARTUP and store.is_stale():
        try:
            await run_scrape()
        except Exception:  # noqa: BLE001
            log.exception("startup scrape failed")

    # Start the scheduler.
    scheduler.start()
    log.info("Scheduler started with %d job(s)", len(scheduler.get_jobs()))

    yield

    # Shutdown the scheduler gracefully.
    scheduler.shutdown(wait=True)
    log.info("Scheduler stopped")


app = FastAPI(
    title="Lumos API",
    version="0.1.0",
    summary="Immigration pathway and compliance tracker — news slice",
    lifespan=lifespan,
)

# ── CORS ──────────────────────────────────────────────────────────────────────
#
# The Flutter web build is served from a different origin in every environment
# (localhost:7357 in dev, a Render static site in prod), so CORS is required —
# but an allow-list, not `*`. `POST /api/news/relevant` takes somebody's
# situation in its body, and a wildcard origin lets any page on the internet
# make a browser send that request.

#: What `scripts/run_web.*` serves the Flutter build on, from .env.
FRONTEND_PORT = int(os.getenv("FRONTEND_PORT", "7357"))
DEV_ORIGINS = (
    f"http://localhost:{FRONTEND_PORT}",
    f"http://127.0.0.1:{FRONTEND_PORT}",
)


def _cors_origins() -> list[str]:
    """The dev origin, plus whatever `CORS_ORIGINS` adds.

    `*` is refused rather than honoured. If a deployment genuinely needs to be
    open to everyone, it has to name the origins — the failure mode of a
    wildcard here is silent and the failure mode of a missing origin is a
    console error somebody will fix in a minute.
    """
    configured = [
        origin.strip()
        for origin in os.getenv("CORS_ORIGINS", "").split(",")
        if origin.strip()
    ]
    if "*" in configured:
        log.warning(
            "CORS_ORIGINS contains '*'; ignoring it. Name the origins explicitly."
        )
        configured = [o for o in configured if o != "*"]

    # dict.fromkeys rather than a set: order is stable, which makes the
    # configuration readable in logs and in tests.
    return list(dict.fromkeys([*DEV_ORIGINS, *configured]))


CORS_ORIGINS = _cors_origins()

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    # Named explicitly so the Authorization header is allowed on purpose rather
    # than as a side effect of a wildcard.
    allow_headers=["Authorization", "Content-Type"],
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


@app.post("/api/news/relevant", response_model=PersonalisedNewsFeed)
async def relevant_news(
    situation: SituationInput,
    days: int | None = Query(
        default=None,
        ge=1,
        le=365,
        description="Only items first seen in the last N days.",
    ),
    limit: int = Query(default=60, ge=1, le=200),
    refine: bool = Query(
        default=False,
        description=(
            "Ask the optional LLM pass to rewrite the wording of the top "
            "'affects you' explanations. The verdicts themselves are always "
            "deterministic. No-op when no API key is configured."
        ),
    ),
    caller: str | None = Depends(optional_caller),
) -> PersonalisedNewsFeed:
    """The same feed as `/api/news/alerts`, sorted by what touches *you*.

    ─────────────────────────────────────────────────────────────────────────
    PRIVACY RULE — DO NOT BREAK THIS.

    `situation` is the person's own account of their immigration status. It is
    accepted per-request for scoring **and is never persisted**. It is not
    written to `app/store.py` (which holds published documents and scrape
    bookkeeping only), not cached, not attached to a caller id, and not logged
    — not the free text, not the resolved node ids, not the country.

    The product tells people the backend stores nothing about them. That claim
    is only true while this endpoint stays a pure function of its arguments, so
    if you are here to add "just a small cache keyed by user" or an analytics
    line that includes `situation`, that is the change that makes the product
    dishonest. Scoring lives in `app/relevance.py` and is deliberately pure and
    stateless for the same reason.

    `caller` is a verified Google subject id when the client sent a token. It
    is *not* used to key anything — it exists so a forged Authorization header
    is rejected rather than trusted. Do not store it either.
    ─────────────────────────────────────────────────────────────────────────

    Accuracy: nothing here says a document affects somebody legally. Every
    verdict is phrased as "this looks relevant to you because …", names the
    concrete signal behind it, and ships with the item's primary-source URL and
    the informational-only disclaimer.
    """
    del caller  # verified, then deliberately discarded — see the note above.

    since = (
        datetime.now(timezone.utc) - timedelta(days=days) if days is not None else None
    )
    items, total = store.items(since=since, limit=limit, offset=0)

    scored = relevance_scorer.rank(items, situation)

    llm_used = False
    if refine and not situation.is_empty:
        llm_used = await relevance_scorer.refine(scored, situation)

    run = store.last_run()
    return PersonalisedNewsFeed(
        items=[
            RelevantNewsItem(item=item, relevance=verdict) for item, verdict in scored
        ],
        total=total,
        counts=counts([verdict for _, verdict in scored]),
        last_scraped_at=run.finished_at if run else None,
        stale=store.is_stale(),
        personalised=not situation.is_empty,
        llm_used=llm_used,
        disclaimer=RELEVANCE_DISCLAIMER,
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
async def intake(
    body: IntakeRequest,
    request: Request,
    caller: str | None = Depends(optional_caller),
) -> IntakeResult:
    """Free text in → a *proposed* current status and goal out.

    Usable signed-out, because it reads nothing and writes nothing. A token, if
    one is sent, is verified strictly and then discarded — this endpoint takes
    the person's own words, so an unverified Authorization header must never be
    treated as an identity.

    Nothing here is persisted; the request body goes out of scope with the
    response and is not logged.
    """
    del caller  # verified, then discarded. Nothing is keyed by identity.
    _rate_limit_intake(request.client.host if request.client else "unknown")
    return await intake_resolver.resolve(body)


@app.post("/api/case/options", response_model=PathwayOptionSet)
async def case_options(
    body: IntakeRequest,
    goal: str | None = Query(
        default=None,
        description=(
            "Force a goal instead of detecting one from the text: "
            + " | ".join(GOALS)
        ),
    ),
    caller: str | None = Depends(optional_caller),
) -> PathwayOptionSet:
    """Every route to a broad goal, ranked and bucketed — never a single answer.

    Separate from `/api/case/intake` because it needs no model, no key and no
    rate limit: the ranking is deterministic over the bundled graph. Intake
    embeds the same object in its `options` field when it reads a broad goal,
    so a client can use either.

    A goal that names a specific status is not a broad goal, and gets a 422
    rather than a landscape nobody asked for.

    Takes the person's situation, so a presented token is verified and then
    discarded; nothing is stored or logged.
    """
    del caller
    if goal is not None and goal not in GOALS:
        raise HTTPException(
            status_code=422,
            detail=f"Unknown goal '{goal}'. Known goals: {', '.join(GOALS)}.",
        )
    result = build_option_set(
        intake_resolver.graph, body.text, body.goal, goal=goal
    )
    if result is None:
        raise HTTPException(
            status_code=422,
            detail=(
                "No broad goal was described. Say what you are trying to do — "
                "for example 'I want to work in the US' — or pass ?goal="
                + "|".join(GOALS)
                + ". For a specific status, use POST /api/case/intake."
            ),
        )
    return result


@app.post("/api/news/refresh", response_model=ScrapeReport)
async def refresh() -> ScrapeReport:
    """Scrape now.

    This is both the manual refresh button and the endpoint a Render Cron Job
    should hit if you move scheduling out of the process.
    """
    if _scrape_lock.locked():
        raise HTTPException(status_code=409, detail="A scrape is already running.")
    return await run_scrape()


# ── Personalized news endpoints (user-specific, requires authentication) ──────


@app.get("/api/user/news/unread", response_model=UnreadNewsFeedResponse)
async def get_unread_news(
    user: User = Depends(required_user),
    db: Session = Depends(get_db),
) -> UnreadNewsFeedResponse:
    """Get unread articles for the authenticated user.

    Requires a valid Google ID token in the Authorization header.
    Returns only articles where is_unread=true, sorted by newest first.
    """
    unread_articles = db.query(UserNews).filter(
        UserNews.user_id == user.id,
        UserNews.is_unread == True,
    ).order_by(UserNews.created_at.desc()).all()

    articles = []
    for user_news in unread_articles:
        article = db.query(NewsArticle).filter(NewsArticle.id == user_news.article_id).first()
        if article:
            articles.append(
                UserNewsArticle(
                    article_id=article.id,
                    title=article.title,
                    link=article.link,
                    summary=article.summary,
                    relevance_reason="",
                    marked_read_at=user_news.marked_read_at,
                    is_unread=user_news.is_unread,
                    personalized_summary=user_news.personalized_summary,
                )
            )

    return UnreadNewsFeedResponse(articles=articles, count=len(articles))


@app.get("/api/user/news/all", response_model=AllNewsFeedResponse)
async def get_all_news(
    user: User = Depends(required_user),
    db: Session = Depends(get_db),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> AllNewsFeedResponse:
    """Get all relevant articles for the authenticated user with pagination.

    Requires a valid Google ID token in the Authorization header.
    Returns both read and unread articles, sorted by scraped_at DESC.
    Supports pagination via limit and offset parameters.
    """
    # Get total count
    total_count = db.query(UserNews).filter(UserNews.user_id == user.id).count()

    # Get paginated results with join to NewsArticle for proper sorting
    user_news_list = db.query(UserNews).join(NewsArticle).filter(
        UserNews.user_id == user.id,
    ).order_by(NewsArticle.scraped_at.desc()).limit(limit).offset(offset).all()

    articles = []
    for user_news in user_news_list:
        article = db.query(NewsArticle).filter(NewsArticle.id == user_news.article_id).first()
        if article:
            articles.append(
                UserNewsArticle(
                    article_id=article.id,
                    title=article.title,
                    link=article.link,
                    summary=article.summary,
                    relevance_reason="",
                    marked_read_at=user_news.marked_read_at,
                    is_unread=user_news.is_unread,
                    personalized_summary=user_news.personalized_summary,
                )
            )

    return AllNewsFeedResponse(
        articles=articles,
        total=total_count,
        limit=limit,
        offset=offset,
    )


@app.post("/api/user/news/{article_id}/read", response_model=MarkReadResponse)
async def mark_news_as_read(
    article_id: str,
    user: User = Depends(required_user),
    db: Session = Depends(get_db),
) -> MarkReadResponse:
    """Mark an article as read for the authenticated user.

    Requires a valid Google ID token in the Authorization header.
    Sets is_unread=false and marked_read_at=now() for the article.
    Returns 404 if the article doesn't exist or isn't relevant to this user.
    """
    user_news = db.query(UserNews).filter(
        UserNews.user_id == user.id,
        UserNews.article_id == article_id,
    ).first()

    if user_news is None:
        raise HTTPException(
            status_code=404,
            detail="Article not found or not relevant to this user",
        )

    now = datetime.now(timezone.utc)
    user_news.is_unread = False
    user_news.marked_read_at = now
    db.commit()

    return MarkReadResponse(status="ok", marked_read_at=now)
