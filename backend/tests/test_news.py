"""Tests for the news slice.

No network: the scraper's HTTP layer is exercised through a stubbed transport,
so these run offline and do not hammer government sites.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

import httpx
import pytest

from app.models import DocumentMeta, NewsItem, ScrapeReport
from app.scraper import Scraper, match_nodes, parse_date
from app.sources import SOURCES_BY_ID, Source, SourceKind
from app.store import NewsStore


# ── Date parsing ──────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("Published 08/11/2026 by USCIS", "2026-08-11"),
        ("August 3, 2026 — notice", "2026-08-03"),
        ("Aug 3, 2026", "2026-08-03"),
        ("2026-07-16 rule", "2026-07-16"),
    ],
)
def test_parse_date_reads_known_formats(text: str, expected: str) -> None:
    parsed = parse_date(text)
    assert parsed is not None
    assert parsed.date().isoformat() == expected


def test_parse_date_returns_none_rather_than_guessing() -> None:
    # A wrong date on an immigration alert is worse than no date.
    assert parse_date("no date anywhere in this text") is None
    assert parse_date("") is None


# ── Node matching ─────────────────────────────────────────────────────────────


def test_declared_related_nodes_win_over_keywords() -> None:
    source = SOURCES_BY_ID["uscis_h1b"]
    assert match_nodes(source, "totally unrelated title", "") == list(
        source.related_nodes
    )


def test_keyword_matching_is_narrow() -> None:
    source = SOURCES_BY_ID["fr_uscis"]
    assert match_nodes(source, "H-1B cap season opens", "registration") == [
        "temp_worker.h1b"
    ]
    # Nothing recognisable means no match, rather than a catch-all.
    assert match_nodes(source, "Meeting of the Advisory Committee", "") == []


# ── HTML extraction ───────────────────────────────────────────────────────────

_FIXTURE = """
<html><body><main>
  <article><a href="/newsroom/one">USCIS Extends Employment Authorization</a>
    <span>08/01/2026</span> Something about EADs and I-765 filings.</article>
  <article><a href="/newsroom/two">H-1B Cap Season Update for FY 2027</a>
    <span>07/15/2026</span> Registration details.</article>
  <article><a href="/more">More</a></article>
</main></body></html>
"""


def test_extract_skips_navigation_and_keeps_articles() -> None:
    source = SOURCES_BY_ID["uscis_newsroom"]
    items = Scraper()._extract(source, _FIXTURE)

    titles = [i.title for i in items]
    assert "USCIS Extends Employment Authorization" in titles
    assert "H-1B Cap Season Update for FY 2027" in titles
    # "More" is 4 characters — navigation chrome, not an article.
    assert "More" not in titles

    h1b = next(i for i in items if "H-1B" in i.title)
    assert h1b.published_at is not None
    assert h1b.published_at.date().isoformat() == "2026-07-15"
    assert "temp_worker.h1b" in h1b.matched_nodes


def test_ids_are_stable_across_runs() -> None:
    source = SOURCES_BY_ID["uscis_newsroom"]
    first = Scraper()._extract(source, _FIXTURE)
    second = Scraper()._extract(source, _FIXTURE)
    assert [i.id for i in first] == [i.id for i in second]


# ── Federal Register ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_federal_register_parses_api_payload() -> None:
    payload = {
        "results": [
            {
                "title": "9-11 Response and Biometric Entry-Exit Fee for H-1B Visas",
                "abstract": "This rule sets the fee.",
                "publication_date": "2026-08-10",
                "html_url": "https://www.federalregister.gov/documents/1",
                "type": "Rule",
                "document_number": "2026-1",
            }
        ]
    }

    def handler(request: httpx.Request) -> httpx.Response:
        # The query is percent-encoded by the time it reaches the transport.
        assert request.url.params.get("conditions[agencies][]") == (
            "u-s-citizenship-and-immigration-services"
        )
        assert request.url.params.get("conditions[publication_date][gte]")
        return httpx.Response(200, json=payload)

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        items = await Scraper()._scrape_federal_register(
            client, SOURCES_BY_ID["fr_uscis"]
        )

    assert len(items) == 1
    item = items[0]
    assert item.published_at is not None
    assert item.published_at.date().isoformat() == "2026-08-10"
    assert "temp_worker.h1b" in item.matched_nodes
    assert "rule" in item.tags


@pytest.mark.asyncio
async def test_federal_register_structured_metadata_is_captured() -> None:
    """The API's own fields, not our reading of the prose.

    Relevance scoring reasons over document type, agency, CFR part and
    effective date (`app/relevance.py`). The API only returns fields you ask
    for by name, so this asserts both halves: that we asked, and that we kept
    what came back.
    """
    payload = {
        "results": [
            {
                "title": "Employment Authorization for Certain Students",
                "abstract": "DHS amends the rules.",
                "publication_date": "2026-08-10",
                "html_url": "https://www.federalregister.gov/documents/9",
                "type": "Rule",
                "document_number": "2026-99",
                "action": "Final rule.",
                "agencies": [
                    {"slug": "u-s-citizenship-and-immigration-services",
                     "name": "U.S. Citizenship and Immigration Services"}
                ],
                "docket_ids": ["USCIS-2026-0001"],
                "cfr_references": [{"title": 8, "part": 274}],
                "effective_on": "2026-10-01",
                "comments_close_on": None,
            }
        ]
    }
    requested: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested.extend(request.url.params.get_list("fields[]"))
        return httpx.Response(200, json=payload)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        items = await Scraper()._scrape_federal_register(
            client, SOURCES_BY_ID["fr_uscis"]
        )

    for field in ("agencies", "cfr_references", "effective_on", "action"):
        assert field in requested, f"the API was never asked for {field}"

    meta = items[0].meta
    assert meta.document_type == "Rule"
    assert meta.action == "Final rule."
    assert meta.agencies == ["u-s-citizenship-and-immigration-services"]
    assert meta.docket_ids == ["USCIS-2026-0001"]
    assert meta.cfr_references == ["8 CFR 274"]
    assert meta.effective_on is not None
    assert meta.effective_on.isoformat() == "2026-10-01"
    # Absent stays absent — a missing comment deadline is not a date.
    assert meta.comments_close_on is None


@pytest.mark.asyncio
async def test_a_source_failure_does_not_sink_the_run() -> None:
    """One blocked government site must not empty the whole feed."""

    def handler(request: httpx.Request) -> httpx.Response:
        if "federalregister.gov" in str(request.url):
            return httpx.Response(
                200,
                json={
                    "results": [
                        {
                            "title": "A notice about immigration benefits",
                            "abstract": "",
                            "publication_date": "2026-08-01",
                            "html_url": "https://www.federalregister.gov/documents/2",
                            "type": "Notice",
                            "document_number": "2026-2",
                        }
                    ]
                },
            )
        # Everything else behaves like uscis.gov does from a blocked network.
        return httpx.Response(403, text="Forbidden")

    scraper = Scraper()
    transport = httpx.MockTransport(handler)

    # Patch the client the run would otherwise build for itself.
    original = httpx.AsyncClient

    def factory(*args, **kwargs):  # noqa: ANN002, ANN003
        kwargs["transport"] = transport
        return original(*args, **kwargs)

    httpx.AsyncClient = factory  # type: ignore[misc]
    try:
        items, report = await scraper.run()
    finally:
        httpx.AsyncClient = original  # type: ignore[misc]

    assert items, "the API sources should still produce a feed"
    assert report.sources_ok, "at least one source succeeded"
    assert report.sources_failed, "the blocked sources are reported, not hidden"
    assert not report.ok


# ── Store ─────────────────────────────────────────────────────────────────────


@pytest.fixture()
def store(tmp_path) -> NewsStore:
    return NewsStore(tmp_path / "news.sqlite3")


def _item(suffix: str, node: str = "temp_worker.h1b") -> NewsItem:
    url = f"https://example.gov/{suffix}"
    title = f"Notice {suffix}"
    return NewsItem(
        id=NewsItem.make_id("fr_uscis", url, title),
        source_id="fr_uscis",
        source_name="Federal Register — USCIS",
        title=title,
        url=url,
        matched_nodes=[node],
    )


def test_saving_is_idempotent(store: NewsStore) -> None:
    assert store.save_items([_item("a"), _item("b")]) == 2
    # A second run over the same page must not duplicate or re-date anything.
    assert store.save_items([_item("a"), _item("b")]) == 0
    _, total = store.items()
    assert total == 2


def test_node_filter_does_not_match_on_prefixes(store: NewsStore) -> None:
    store.save_items(
        [
            _item("x", node="student.opt_postcompletion"),
            _item("y", node="temp_worker.h1b"),
        ]
    )
    _, opt_total = store.items(node_id="student.opt")
    assert opt_total == 0, "student.opt must not match student.opt_postcompletion"

    _, exact = store.items(node_id="student.opt_postcompletion")
    assert exact == 1


def test_no_runs_yet_reads_as_stale(store: NewsStore) -> None:
    # Never having checked is not the same as being up to date.
    assert store.is_stale()


def test_a_recent_run_is_not_stale(store: NewsStore) -> None:
    now = datetime.now(timezone.utc)
    store.save_run(
        ScrapeReport(started_at=now, finished_at=now, items_found=1, items_new=1)
    )
    assert not store.is_stale()


def test_a_run_older_than_the_daily_cadence_is_stale(store: NewsStore) -> None:
    old = datetime.now(timezone.utc) - timedelta(days=3)
    store.save_run(
        ScrapeReport(started_at=old, finished_at=old, items_found=1, items_new=1)
    )
    assert store.is_stale(max_age=timedelta(hours=36))


def test_metadata_survives_a_round_trip(store: NewsStore) -> None:
    item = _item("meta")
    item.meta = DocumentMeta(
        document_type="Proposed Rule",
        agencies=["u-s-citizenship-and-immigration-services"],
        cfr_references=["8 CFR 214"],
        effective_on=date(2026, 12, 1),
    )
    store.save_items([item])

    stored, _ = store.items()
    assert stored[0].meta.document_type == "Proposed Rule"
    assert stored[0].meta.cfr_references == ["8 CFR 214"]
    assert stored[0].meta.effective_on == date(2026, 12, 1)


def test_a_database_written_before_metadata_existed_still_opens(tmp_path) -> None:
    """`CREATE TABLE IF NOT EXISTS` does nothing to an existing table.

    Without the migration, a deploy over an existing SQLite file would fail
    every read — which on this service means the feed silently empties.
    """
    import sqlite3

    path = tmp_path / "old.sqlite3"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE news_items (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, source_name TEXT NOT NULL,
            title TEXT NOT NULL, url TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '',
            published_at TEXT, first_seen_at TEXT NOT NULL,
            matched_nodes TEXT NOT NULL DEFAULT '[]', tags TEXT NOT NULL DEFAULT '[]'
        );
        """
    )
    conn.execute(
        "INSERT INTO news_items (id, source_id, source_name, title, url, first_seen_at)"
        " VALUES ('old_1', 'fr_uscis', 'FR', 'An older notice',"
        " 'https://example.gov/old', '2026-01-01T00:00:00+00:00')"
    )
    conn.commit()
    conn.close()

    items, total = NewsStore(path).items()
    assert total == 1
    assert items[0].title == "An older notice"
    # The pre-existing row simply carries no structured metadata.
    assert items[0].meta.document_type == ""


def test_source_info_reports_failures(store: NewsStore) -> None:
    now = datetime.now(timezone.utc)
    store.save_run(
        ScrapeReport(
            started_at=now,
            finished_at=now,
            items_found=0,
            items_new=0,
            sources_ok=["fr_uscis"],
            sources_failed={"uscis_newsroom": "HTTPStatusError: 403"},
        )
    )
    by_id = {s.id: s for s in store.source_info()}
    assert by_id["fr_uscis"].last_scraped_at is not None
    assert by_id["fr_uscis"].last_error is None
    # The blocked source is surfaced with its error rather than quietly dropped.
    assert by_id["uscis_newsroom"].last_error is not None
    assert by_id["uscis_newsroom"].last_scraped_at is None
