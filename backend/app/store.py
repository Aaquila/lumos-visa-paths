"""Persistence for scraped news.

SQLite, via the standard library. This is deliberately the smallest thing that
survives a restart: Render's free tier recycles processes, and losing the feed
on every deploy would make the daily cadence meaningless. When the Postgres
schema in PROJECT_PRD §7a lands, `news_alerts` replaces this table and the
`user_id` matching moves into SQL — the shapes here are already compatible.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .models import NewsItem, ScrapeReport, SourceInfo, utcnow
from .sources import SOURCES

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "news.sqlite3"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS news_items (
    id            TEXT PRIMARY KEY,
    source_id     TEXT NOT NULL,
    source_name   TEXT NOT NULL,
    title         TEXT NOT NULL,
    url           TEXT NOT NULL,
    summary       TEXT NOT NULL DEFAULT '',
    published_at  TEXT,
    first_seen_at TEXT NOT NULL,
    matched_nodes TEXT NOT NULL DEFAULT '[]',
    tags          TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS idx_news_seen ON news_items(first_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_news_source ON news_items(source_id);

CREATE TABLE IF NOT EXISTS scrape_runs (
    started_at     TEXT PRIMARY KEY,
    finished_at    TEXT NOT NULL,
    items_found    INTEGER NOT NULL,
    items_new      INTEGER NOT NULL,
    sources_ok     TEXT NOT NULL DEFAULT '[]',
    sources_failed TEXT NOT NULL DEFAULT '{}'
);
"""


class NewsStore:
    def __init__(self, path: Path = DB_PATH) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(_SCHEMA)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    # ── Writes ────────────────────────────────────────────────────────────────

    def save_items(self, items: list[NewsItem]) -> int:
        """Insert items we have not seen before. Returns the number of new ones.

        Existing rows keep their original `first_seen_at`, so "new since
        yesterday" stays meaningful across runs.
        """
        new = 0
        with self._connect() as conn:
            for item in items:
                cursor = conn.execute(
                    """
                    INSERT OR IGNORE INTO news_items
                        (id, source_id, source_name, title, url, summary,
                         published_at, first_seen_at, matched_nodes, tags)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        item.id,
                        item.source_id,
                        item.source_name,
                        item.title,
                        str(item.url),
                        item.summary,
                        item.published_at.isoformat() if item.published_at else None,
                        item.first_seen_at.isoformat(),
                        json.dumps(item.matched_nodes),
                        json.dumps(item.tags),
                    ),
                )
                new += cursor.rowcount
        return new

    def save_run(self, report: ScrapeReport) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO scrape_runs
                    (started_at, finished_at, items_found, items_new,
                     sources_ok, sources_failed)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    report.started_at.isoformat(),
                    report.finished_at.isoformat(),
                    report.items_found,
                    report.items_new,
                    json.dumps(report.sources_ok),
                    json.dumps(report.sources_failed),
                ),
            )

    # ── Reads ─────────────────────────────────────────────────────────────────

    @staticmethod
    def _to_item(row: sqlite3.Row) -> NewsItem:
        return NewsItem(
            id=row["id"],
            source_id=row["source_id"],
            source_name=row["source_name"],
            title=row["title"],
            url=row["url"],
            summary=row["summary"],
            published_at=(
                datetime.fromisoformat(row["published_at"])
                if row["published_at"]
                else None
            ),
            first_seen_at=datetime.fromisoformat(row["first_seen_at"]),
            matched_nodes=json.loads(row["matched_nodes"]),
            tags=json.loads(row["tags"]),
        )

    def items(
        self,
        *,
        node_id: str | None = None,
        source_id: str | None = None,
        since: datetime | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> tuple[list[NewsItem], int]:
        clauses: list[str] = []
        params: list[object] = []

        if source_id:
            clauses.append("source_id = ?")
            params.append(source_id)
        if since:
            clauses.append("first_seen_at >= ?")
            params.append(since.isoformat())
        if node_id:
            # matched_nodes is a JSON array; the quoted form avoids matching
            # `student.opt` inside `student.opt_postcompletion`.
            clauses.append("matched_nodes LIKE ?")
            params.append(f'%"{node_id}"%')

        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""

        with self._connect() as conn:
            total = conn.execute(
                f"SELECT COUNT(*) FROM news_items {where}", params
            ).fetchone()[0]
            rows = conn.execute(
                f"""
                SELECT * FROM news_items {where}
                ORDER BY COALESCE(published_at, first_seen_at) DESC
                LIMIT ? OFFSET ?
                """,
                [*params, limit, offset],
            ).fetchall()

        return [self._to_item(r) for r in rows], total

    def last_run(self) -> ScrapeReport | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM scrape_runs ORDER BY started_at DESC LIMIT 1"
            ).fetchone()
        if row is None:
            return None
        return ScrapeReport(
            started_at=datetime.fromisoformat(row["started_at"]),
            finished_at=datetime.fromisoformat(row["finished_at"]),
            items_found=row["items_found"],
            items_new=row["items_new"],
            sources_ok=json.loads(row["sources_ok"]),
            sources_failed=json.loads(row["sources_failed"]),
        )

    def is_stale(self, max_age: timedelta = timedelta(hours=36)) -> bool:
        """True when the last run is older than a day and a half.

        The cadence is daily; 36 hours allows one missed run before the client
        starts warning that the feed may be behind.
        """
        run = self.last_run()
        if run is None:
            return True
        finished = run.finished_at
        if finished.tzinfo is None:
            finished = finished.replace(tzinfo=timezone.utc)
        return utcnow() - finished > max_age

    def source_info(self) -> list[SourceInfo]:
        run = self.last_run()
        with self._connect() as conn:
            counts = {
                r["source_id"]: r["n"]
                for r in conn.execute(
                    "SELECT source_id, COUNT(*) AS n FROM news_items GROUP BY source_id"
                )
            }
        return [
            SourceInfo(
                id=s.id,
                name=s.name,
                url=s.url,
                related_nodes=list(s.related_nodes),
                tags=list(s.tags),
                last_scraped_at=(
                    run.finished_at if run and s.id in run.sources_ok else None
                ),
                last_error=(run.sources_failed.get(s.id) if run else None),
                item_count=counts.get(s.id, 0),
            )
            for s in SOURCES
        ]
