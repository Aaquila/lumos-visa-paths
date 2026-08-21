"""Background job: match new articles to users based on their visa situations.

This module is called after each scrape completes to:
1. Find all new articles scraped since last personalization
2. Get all users with recorded visa situations
3. Score each new article against each user's situation
4. Create UserNews records for relevant matches

The scoring is deterministic (no LLM calls) and based on the existing
RelevanceScorer infrastructure, which checks visa categories, forms,
CFR references, and other structured signals in the article metadata.

Privacy: User situations are read from the database, scored in memory
against articles, and no user-identifying data is logged.
"""

from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timezone

from sqlalchemy.orm import Session

from .models import DocumentMeta, NewsItem, SituationInput
from .database import NewsArticle, UserNews, UserVisaSituation, utcnow, SessionLocal
from .relevance import BACKGROUND, RelevanceScorer
from .summarizer import PersonalizedSummarizer

log = logging.getLogger("lumos.personalization")

#: Process users in batches to avoid memory spikes on large user bases.
BATCH_SIZE = 10


def _to_news_item(article: NewsArticle) -> NewsItem:
    """Rebuild the `NewsItem` the scorer expects from a stored `NewsArticle`.

    `matched_nodes`/`meta` are JSON text on the row (see `NewsArticle` in
    `database.py`) — the same encoding `store.py` uses for `news_items` — so a
    malformed or pre-migration blank value (`'[]'`/`'{}'`) degrades to "no
    structured signal" rather than raising.
    """
    try:
        matched_nodes = json.loads(article.matched_nodes or "[]")
    except (TypeError, ValueError):
        matched_nodes = []
    try:
        meta = DocumentMeta.model_validate_json(article.meta or "{}")
    except (TypeError, ValueError):
        meta = DocumentMeta()

    return NewsItem(
        id=article.id,
        source_id=article.source,
        source_name=article.source,
        title=article.title,
        url=article.link,
        summary=article.summary,
        published_at=article.published_at,
        first_seen_at=article.scraped_at,
        matched_nodes=matched_nodes,
        meta=meta,
    )


def sync_scraped_articles(items: list[NewsItem]) -> int:
    """Copy scraped items into `NewsArticle`, the table personalization reads.

    The scraper's raw feed lives in `store.py`'s own SQLite file (the
    `news_items` table, read by the public `/api/news/alerts` endpoint).
    `personalize_articles` below scores a *separate* table, `NewsArticle`, in
    this database — and until this function existed, nothing ever wrote to
    it, so `personalize_articles` always found zero articles and created zero
    `UserNews` matches, no matter how much scoring or summarization logic
    existed downstream. Call this once per scrape, with the same items just
    written to the scraper's own store, before `personalize_articles`.

    Idempotent by `id` (same hash scheme as `store.py`): an article already
    present has its mutable fields (title, summary, published date) refreshed
    in place rather than being duplicated. `link` is unique on `NewsArticle`,
    so a row is also matched by link if the id doesn't (yet) match — an id
    changes only if the source edited the title, and the row should still be
    treated as the same article, not a new one with a dangling old id that
    `UserNews.article_id` might still reference.

    Also matched by link *within this call*, not just against the database:
    the same Federal Register document can legitimately surface twice in one
    scrape — once per agency search that returns it (e.g. a joint DHS/State
    notice) — as two `NewsItem`s with different `id`s (the hash includes
    `source_id`) but the same `link`. Nothing is flushed between loop
    iterations, so a DB-only existence check can't see the first one already
    staged for insert; both would look new and collide on the `link` unique
    constraint at commit. `_matched` tracks what this call has already
    resolved so the second occurrence updates the first instead.

    Returns how many articles were newly inserted.
    """
    if not items:
        return 0

    db = SessionLocal()
    try:
        inserted = 0
        matched: dict[str, NewsArticle] = {}
        for item in items:
            link = str(item.url)
            existing = matched.get(link) or (
                db.query(NewsArticle)
                .filter((NewsArticle.id == item.id) | (NewsArticle.link == link))
                .first()
            )
            if existing is None:
                existing = NewsArticle(
                    id=item.id,
                    title=item.title,
                    link=link,
                    summary=item.summary,
                    published_at=item.published_at,
                    scraped_at=item.first_seen_at,
                    source=item.source_name or item.source_id,
                    matched_nodes=json.dumps(item.matched_nodes),
                    meta=item.meta.model_dump_json(),
                )
                db.add(existing)
                inserted += 1
            else:
                existing.title = item.title
                existing.summary = item.summary
                if item.published_at is not None:
                    existing.published_at = item.published_at
                # A later scrape can carry richer node-matching/metadata for an
                # article that was already synced (e.g. pathways.py learned a
                # new node) — refresh rather than leaving the first pass stuck.
                existing.matched_nodes = json.dumps(item.matched_nodes)
                existing.meta = item.meta.model_dump_json()
            matched[link] = existing
        db.commit()
        return inserted
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


async def personalize_articles(
    scorer: RelevanceScorer, summarizer: PersonalizedSummarizer | None = None
) -> dict[str, int]:
    """Match new articles to users based on their visa situations.

    Called after each scrape completes. When `summarizer` is given and has a
    working Claude client, each new match also gets a personalized headline
    and explanation (`UserNews.personalized_headline`/`personalized_summary`)
    — best-effort; a failed or skipped generation just leaves the fields null
    and callers fall back to the article's own title and raw scraped summary.
    Returns a summary dict with keys:
    - 'users_processed': how many users were evaluated
    - 'articles_evaluated': how many new articles × users were scored
    - 'matches_created': how many new UserNews records were created

    Logic:
    1. Fetch all news articles (scored articles are new for personalization)
    2. Get all users with recorded visa situations
    3. For each user in batches:
       - Get their latest visa situation
       - For each article:
         - Score article against their situation using RelevanceScorer
         - If relevant (not 'background'), create UserNews record
         - Skip if UserNews already exists (no duplicates)
    4. Return summary
    """
    db = SessionLocal()

    try:
        # Get all users with visa situations
        users = db.query(UserVisaSituation).all()
        if not users:
            log.info("personalization: no users with visa situations, skipping")
            return {
                "users_processed": 0,
                "articles_evaluated": 0,
                "matches_created": 0,
            }

        # Get all articles (in a real system, we'd filter by "new since last run")
        articles = db.query(NewsArticle).all()
        if not articles:
            log.info("personalization: no articles, skipping")
            return {
                "users_processed": 0,
                "articles_evaluated": 0,
                "matches_created": 0,
            }

        log.info("personalization: processing %d articles against %d users", len(articles), len(users))

        stats = {
            "users_processed": 0,
            "articles_evaluated": 0,
            "matches_created": 0,
        }

        # Convert NewsArticle ORM objects to NewsItem Pydantic models for scoring
        items_for_scoring: list[NewsItem] = []
        for article in articles:
            try:
                items_for_scoring.append(_to_news_item(article))
            except Exception as e:  # noqa: BLE001
                log.warning("failed to convert article %s: %s", article.id, e)
                continue

        # Process users in batches to avoid memory spike
        for batch_start in range(0, len(users), BATCH_SIZE):
            batch_end = min(batch_start + BATCH_SIZE, len(users))
            batch = users[batch_start:batch_end]

            for situation_record in batch:
                # Build a SituationInput from the user's recorded situation
                situation = SituationInput(
                    status_text=situation_record.current_status_text,
                    goal_text=situation_record.goal_text,
                )

                # Score all articles against this user's situation
                scored = scorer.rank(items_for_scoring, situation)

                for item, verdict in scored:
                    stats["articles_evaluated"] += 1

                    # Only create a record if the article is relevant
                    if verdict.level == BACKGROUND:
                        continue

                    # Check for duplicates
                    existing = db.query(UserNews).filter(
                        UserNews.user_id == situation_record.user_id,
                        UserNews.article_id == item.id,
                    ).first()
                    if existing is not None:
                        continue

                    # Create the UserNews record
                    user_news = UserNews(
                        user_id=situation_record.user_id,
                        article_id=item.id,
                        is_unread=True,
                        relevance_reason=verdict.reason,
                        relevance_level=verdict.level,
                        created_at=utcnow(),
                    )

                    if summarizer is not None and summarizer.available:
                        try:
                            insight = await summarizer.summarize(item, situation)
                        except Exception:  # noqa: BLE001
                            log.warning(
                                "personalized summary failed for article %s; "
                                "falling back to the raw summary",
                                item.id,
                            )
                            insight = None
                        if insight:
                            user_news.personalized_headline = insight.headline
                            user_news.personalized_summary = insight.summary
                            user_news.summary_generated_at = utcnow()

                    db.add(user_news)
                    stats["matches_created"] += 1

                stats["users_processed"] += 1

        db.commit()

        log.info(
            "personalization complete: processed %d users, evaluated %d articles, "
            "created %d matches",
            stats["users_processed"],
            stats["articles_evaluated"],
            stats["matches_created"],
        )

        return stats

    except Exception as e:
        log.exception("personalization failed: %s", e)
        db.rollback()
        raise
    finally:
        db.close()


def refresh_relevance_levels(
    db: Session,
    user_id: str,
    pairs: list[tuple[UserNews, NewsArticle]],
    scorer: RelevanceScorer,
) -> None:
    """Recompute `relevance_level`/`relevance_reason` for a page of matches.

    `relevance_level` was added to `UserNews` after matches already existed,
    and the SQLite migration backfilled every pre-existing row with the
    column's default ('worth_knowing') — indistinguishable on the wire from a
    row that was genuinely scored `worth_knowing`. There is no way to tell
    "never scored" apart from "scored worth_knowing" once that default has
    been written, so the only correct fix is to re-run the deterministic
    scorer (cheap — no LLM call) rather than only filling in blanks. Matches
    every article's article-only reasoning (unlike `personalize_articles`,
    it doesn't know per-user matched pathway nodes, which is fine — the level
    a document earns from its own content doesn't depend on that).

    Never downgrades a row to `background`: if the scorer's rules changed
    since the match was created and it now reads as background, the row still
    represents a real match a person is relying on, so its existing level is
    left alone rather than silently vanishing from "affects you".
    """
    if not pairs:
        return

    situation_record = (
        db.query(UserVisaSituation)
        .filter(UserVisaSituation.user_id == user_id)
        .first()
    )
    if situation_record is None:
        return
    situation = SituationInput(
        status_text=situation_record.current_status_text,
        goal_text=situation_record.goal_text,
    )

    items = []
    by_id: dict[str, tuple[UserNews, NewsArticle]] = {}
    for user_news, article in pairs:
        try:
            items.append(_to_news_item(article))
        except Exception as e:  # noqa: BLE001
            log.warning("failed to convert article %s: %s", article.id, e)
            continue
        by_id[article.id] = (user_news, article)

    changed = False
    for item, verdict in scorer.rank(items, situation):
        user_news, _article = by_id[item.id]
        if verdict.level == BACKGROUND:
            continue
        if (
            user_news.relevance_level != verdict.level
            or user_news.relevance_reason != verdict.reason
        ):
            user_news.relevance_level = verdict.level
            user_news.relevance_reason = verdict.reason
            changed = True

    if changed:
        db.commit()


async def ensure_personalized_summaries(
    db: Session,
    user_id: str,
    pairs: list[tuple[UserNews, NewsArticle]],
    summarizer: PersonalizedSummarizer,
    max_generate: int = 10,
) -> None:
    """Best-effort lazy backfill for a page of results that predate this feature.

    `personalize_articles` never revisits an existing `UserNews` match, so
    matches created before personalized insights existed (or before the
    prompt improved) would otherwise show the raw scraped text forever. This
    fills `personalized_headline`/`personalized_summary` for up to
    `max_generate` still-null rows in `pairs` — bounded so one page load
    can't trigger unbounded LLM spend — and commits the result so later
    requests reuse it. Called from the `/api/user/news/*` read endpoints,
    right before building the response.

    Silently does nothing (leaving the raw title/summary as the fallback) if
    there is no working Claude client or no recorded situation for this user.
    """
    if not summarizer.available:
        return

    missing = [
        (user_news, article)
        for user_news, article in pairs
        if not user_news.personalized_headline
    ][:max_generate]
    if not missing:
        return

    situation_record = (
        db.query(UserVisaSituation)
        .filter(UserVisaSituation.user_id == user_id)
        .first()
    )
    if situation_record is None:
        return
    situation = SituationInput(
        status_text=situation_record.current_status_text,
        goal_text=situation_record.goal_text,
    )

    async def _fill(user_news: UserNews, article: NewsArticle) -> None:
        try:
            item = _to_news_item(article)
        except Exception as e:  # noqa: BLE001
            log.warning("failed to convert article %s: %s", article.id, e)
            return
        try:
            insight = await summarizer.summarize(item, situation)
        except Exception:  # noqa: BLE001
            log.warning(
                "lazy personalized-summary backfill failed for article %s",
                article.id,
            )
            return
        if insight:
            user_news.personalized_headline = insight.headline
            user_news.personalized_summary = insight.summary
            user_news.summary_generated_at = utcnow()

    await asyncio.gather(*(_fill(un, art) for un, art in missing))
    db.commit()


__all__ = [
    "sync_scraped_articles",
    "personalize_articles",
    "refresh_relevance_levels",
    "ensure_personalized_summaries",
]
