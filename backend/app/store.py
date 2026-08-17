"""Persistence for scraped news and user data.

Database connection, session management, and schema creation. Supports both
SQLite (local dev) and Postgres (production). Uses SQLAlchemy ORM for all
models defined in `.models`.

**Database selection:**
- If `DATABASE_URL` env var is set, uses that connection string (Postgres)
- Otherwise, falls back to SQLite at `backend/data/news.sqlite3`

**Privacy rule, load-bearing.** Every table here holds *published government
documents*, *shared user data* (news articles), or *our own scrape bookkeeping*.
Nothing from `SituationInput` is written — the relevance endpoint scores a
person's situation in memory and drops it with the response. If you find
yourself adding a column, a table or a parameter that would hold what somebody
told us about themselves, that is the change the product promised not to make —
see the note above `POST /api/news/relevant` in `app/main.py`.
"""

from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker

from .database import Base, utcnow
from .models import (
    DocumentMeta,
    NewsItem,
    ScrapeReport,
    SourceInfo,
)
from .sources import SOURCES

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "news.sqlite3"

# ── Database Engine and Session Management ────────────────────────────────────

DATABASE_URL = os.getenv("DATABASE_URL")

if DATABASE_URL:
    # Production: use Postgres from environment
    engine = create_engine(
        DATABASE_URL,
        echo=os.getenv("SQL_ECHO", "").lower() == "true",
        pool_pre_ping=True,  # Test connections before using them
    )
else:
    # Local dev: use SQLite
    db_path = DB_PATH
    db_path.parent.mkdir(parents=True, exist_ok=True)
    engine = create_engine(
        f"sqlite:///{db_path}",
        echo=os.getenv("SQL_ECHO", "").lower() == "true",
        connect_args={"check_same_thread": False},  # SQLite only
    )

    # SQLite: enable foreign keys on connection
    @event.listens_for(engine, "connect")
    def set_sqlite_pragma(dbapi_connection, _):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()


# Create all tables on engine initialization
Base.metadata.create_all(engine)

# Session factory for ORM operations
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

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
    tags          TEXT NOT NULL DEFAULT '[]',
    meta          TEXT NOT NULL DEFAULT '{}'
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
            self._migrate(conn)

    @staticmethod
    def _migrate(conn: sqlite3.Connection) -> None:
        """Add columns a previously-created database is missing.

        `CREATE TABLE IF NOT EXISTS` does nothing to an existing table, so a
        database written before `meta` existed would otherwise fail every read
        after a deploy. Adding the column is safe and idempotent; existing rows
        get the default and simply carry no structured metadata until the next
        scrape re-reads them.
        """
        existing = {r["name"] for r in conn.execute("PRAGMA table_info(news_items)")}
        if "meta" not in existing:
            conn.execute(
                "ALTER TABLE news_items ADD COLUMN meta TEXT NOT NULL DEFAULT '{}'"
            )

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
                         published_at, first_seen_at, matched_nodes, tags, meta)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        item.meta.model_dump_json(),
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
        keys = row.keys()
        raw_meta = row["meta"] if "meta" in keys else None
        try:
            meta = DocumentMeta.model_validate_json(raw_meta or "{}")
        except ValueError:
            # A metadata blob we cannot read is worth less than the item is; a
            # story with no structured fields still belongs in the feed.
            meta = DocumentMeta()

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
            meta=meta,
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
