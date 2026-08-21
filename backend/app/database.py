"""Database models and session management for user personalization."""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import (
    Column, String, Text, Integer, Boolean, DateTime, ForeignKey, Index, create_engine, event,
    inspect,
)
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session, relationship

# Load .env from the repo root before any os.getenv calls.
_env_path = Path(__file__).parent.parent.parent / '.env'

# Database URL from environment, defaulting to SQLite for development.
# Uses news.sqlite3 which has the user data (users, situations, personalization)
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    f"sqlite:///{Path(__file__).resolve().parent.parent / 'data' / 'news.sqlite3'}"
)

# Create engine with appropriate settings for the database type.
if DATABASE_URL.startswith("postgresql://") or DATABASE_URL.startswith("postgres://"):
    # PostgreSQL: use connection pooling settings suitable for production
    engine = create_engine(
        DATABASE_URL,
        pool_size=10,
        max_overflow=20,
        pool_pre_ping=True,
        echo=False,
    )
else:
    # SQLite: use check_same_thread=False for development
    engine = create_engine(
        DATABASE_URL,
        connect_args={"check_same_thread": False} if "sqlite" in DATABASE_URL else {},
        echo=False,
    )

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def utcnow() -> datetime:
    """Current time in UTC."""
    return datetime.now(timezone.utc)


class User(Base):
    """User account linked to Google OAuth sub (immutable primary key).

    The `id` is the Google ID token's `sub` claim, verified on each request.
    Nothing private (email, preferences, location) is stored; only the identity
    and sign-in tracking.
    """

    __tablename__ = "users"

    id = Column(String(256), primary_key=True)  # Google OAuth sub
    created_at = Column(DateTime(timezone=True), default=utcnow, nullable=False)
    last_signin = Column(DateTime(timezone=True), nullable=True)

    # Relationships
    visa_situations = relationship(
        "UserVisaSituation", back_populates="user", cascade="all, delete-orphan"
    )
    news = relationship("UserNews", back_populates="user", cascade="all, delete-orphan")
    preferences = relationship(
        "UserPreferences", back_populates="user", cascade="all, delete-orphan", uselist=False
    )


class UserVisaSituation(Base):
    """Free-text visa status and goals for one user.

    Holds the person's current status as they stated it, plus their goal.
    Updated when they confirm intake or update their situation. Only one per user.
    """

    __tablename__ = "user_visa_situations"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(256), ForeignKey("users.id"), nullable=False, unique=True)
    current_status_text = Column(Text, default="", nullable=False)
    current_status_chip = Column(String(100), default="", nullable=False)
    expiry_date = Column(DateTime(timezone=True), nullable=True)
    is_expiry_approximate = Column(Boolean, default=False, nullable=False)
    goal_text = Column(Text, default="", nullable=False)
    updated_at = Column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    # Relationships
    user = relationship("User", back_populates="visa_situations")


class NewsArticle(Base):
    """Published news item from a scraped source.

    Shared across all users. Stable `id` based on source + URL + title hash.
    Scraped_at tracks when we fetched it; published_at is the source's date
    (may be absent for unparseable sources).
    """

    __tablename__ = "news_articles"

    id = Column(String(256), primary_key=True)  # Hash: news_<sha256[:16]>
    title = Column(String(1024), nullable=False)
    link = Column(String(2048), nullable=False, unique=True)
    summary = Column(Text, default="", nullable=False)
    published_at = Column(DateTime(timezone=True), nullable=True)
    scraped_at = Column(DateTime(timezone=True), default=utcnow, nullable=False, index=True)
    source = Column(String(256), nullable=False, index=True)

    #: JSON array of pathway node ids, and JSON-encoded `DocumentMeta`, both
    #: copied verbatim from the scraper's `NewsItem` (see `store.py`'s
    #: `news_items` table for the same encoding). Without these, personalization
    #: scores on bare title/summary text alone and structured Federal Register
    #: signals (CFR references, agencies, document type) never reach the scorer.
    matched_nodes = Column(Text, default="[]", nullable=False)
    meta = Column(Text, default="{}", nullable=False)

    # Relationships
    user_news = relationship("UserNews", back_populates="article", cascade="all, delete-orphan")


class UserNews(Base):
    """Per-user tracking of a news article (unread status, relevance, read date).

    Joins User and NewsArticle. Tracks whether the person has read it, why it
    was relevant to them, and when they marked it read. Indexed by user_id
    for efficient "get my unread news" queries.
    """

    __tablename__ = "user_news"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(256), ForeignKey("users.id"), nullable=False, index=True)
    article_id = Column(String(256), ForeignKey("news_articles.id"), nullable=False)
    is_unread = Column(Boolean, default=True, nullable=False, index=True)
    relevance_reason = Column(Text, default="", nullable=False)

    #: One of `relevance.AFFECTS_YOU` / `WORTH_KNOWING` — `BACKGROUND` matches
    #: never get a `UserNews` row at all, so this column is never that value.
    #: Lets the client filter "affects you" from "worth knowing" without the
    #: server re-deriving it.
    relevance_level = Column(String(32), default="worth_knowing", nullable=False)

    marked_read_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow, nullable=False, index=True)

    #: Claude-written one-line "what this means for you" headline, personalized
    #: to the user's own status/goal text — or the literal
    #: `summarizer.NOT_RELEVANT_HEADLINE` when the document doesn't touch their
    #: situation. Null until generated (see `app.summarizer`); a null value
    #: means "not generated yet or generation failed", not "nothing to say" —
    #: callers fall back to `NewsArticle.title`.
    personalized_headline = Column(Text, nullable=True)

    #: The plain-language explanation behind `personalized_headline`. Null
    #: until generated; callers fall back to `NewsArticle.summary`.
    personalized_summary = Column(Text, nullable=True)
    summary_generated_at = Column(DateTime(timezone=True), nullable=True)

    # Composite index for efficient querying: user_id + is_unread
    __table_args__ = (
        Index("idx_user_unread", "user_id", "is_unread"),
    )

    # Relationships
    user = relationship("User", back_populates="news")
    article = relationship("NewsArticle", back_populates="user_news")


class UserPreferences(Base):
    """Optional per-user settings (notifications, chosen name, etc).

    Only one per user. May be absent for users who haven't customized anything.
    """

    __tablename__ = "user_preferences"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(256), ForeignKey("users.id"), nullable=False, unique=True)
    notification_enabled = Column(Boolean, default=True, nullable=False)
    chosen_name = Column(String(256), default="", nullable=False)
    updated_at = Column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )

    # Relationships
    user = relationship("User", back_populates="preferences")


def init_db() -> None:
    """Create all tables, then add columns an existing database is missing.

    `create_all` only creates tables that don't exist yet — it never alters an
    existing table, so a `user_news` row written before `personalized_summary`
    existed would otherwise be invisible to every read after a deploy.
    `ALTER TABLE ... ADD COLUMN` is safe and idempotent on both SQLite and
    Postgres; existing rows get NULL (or the given default) until the next
    personalization pass fills them in.
    """
    Base.metadata.create_all(bind=engine)

    datetime_type = "DATETIME" if DATABASE_URL.startswith("sqlite") else "TIMESTAMPTZ"
    inspector = inspect(engine)

    with engine.connect() as conn:
        existing = {col["name"] for col in inspector.get_columns("user_news")}
        for column, ddl_type in (
            ("personalized_summary", "TEXT"),
            ("personalized_headline", "TEXT"),
            ("summary_generated_at", datetime_type),
            ("relevance_level", "VARCHAR(32) NOT NULL DEFAULT 'worth_knowing'"),
        ):
            if column not in existing:
                conn.exec_driver_sql(
                    f"ALTER TABLE user_news ADD COLUMN {column} {ddl_type}"
                )

        existing_articles = {col["name"] for col in inspector.get_columns("news_articles")}
        for column, ddl_type in (
            ("matched_nodes", "TEXT NOT NULL DEFAULT '[]'"),
            ("meta", "TEXT NOT NULL DEFAULT '{}'"),
        ):
            if column not in existing_articles:
                conn.exec_driver_sql(
                    f"ALTER TABLE news_articles ADD COLUMN {column} {ddl_type}"
                )
        conn.commit()


def get_db() -> Session:
    """FastAPI dependency: yields a database session."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
