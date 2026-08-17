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

import logging
from datetime import datetime, timezone

from sqlalchemy.orm import Session

from .models import NewsItem, SituationInput
from .database import NewsArticle, UserNews, UserVisaSituation, utcnow, SessionLocal
from .relevance import BACKGROUND, RelevanceScorer
from .summarizer import PersonalizedSummarizer

log = logging.getLogger("lumos.personalization")

#: Process users in batches to avoid memory spikes on large user bases.
BATCH_SIZE = 10


async def personalize_articles(
    scorer: RelevanceScorer, summarizer: PersonalizedSummarizer | None = None
) -> dict[str, int]:
    """Match new articles to users based on their visa situations.

    Called after each scrape completes. When `summarizer` is given and has a
    working Claude client, each new match also gets a personalized
    plain-language summary (`UserNews.personalized_summary`) — best-effort;
    a failed or skipped generation just leaves the field null and callers
    fall back to the article's raw scraped summary. Returns a summary dict
    with keys:
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
                item = NewsItem(
                    id=article.id,
                    source_id=article.source,
                    source_name=article.source,
                    title=article.title,
                    url=article.link,
                    summary=article.summary,
                    published_at=article.published_at,
                    first_seen_at=article.scraped_at,
                    matched_nodes=[],  # No matched nodes from scraped items
                )
                items_for_scoring.append(item)
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
                        created_at=utcnow(),
                    )

                    if summarizer is not None and summarizer.available:
                        try:
                            personalized = await summarizer.summarize(item, situation)
                        except Exception:  # noqa: BLE001
                            log.warning(
                                "personalized summary failed for article %s; "
                                "falling back to the raw summary",
                                item.id,
                            )
                            personalized = None
                        if personalized:
                            user_news.personalized_summary = personalized
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


__all__ = [
    "personalize_articles",
]
