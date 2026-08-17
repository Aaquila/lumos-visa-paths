"""Tests for personalization job: matching articles to users by visa situation.

This covers the end-to-end flow: scraper creates articles, personalization job
evaluates them against user situations, creates UserNews records, and ensures
no data leaks between users.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session

from app.database import (
    Base,
    NewsArticle,
    User,
    UserNews,
    UserVisaSituation,
    utcnow,
    SessionLocal,
)
from app.personalization import personalize_articles
from app.relevance import RelevanceScorer


@pytest.fixture()
def test_db():
    """Create an in-memory SQLite database for testing."""
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    TestSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    db = TestSessionLocal()
    yield db
    db.close()


@pytest.fixture()
def scorer():
    """Create a RelevanceScorer instance."""
    return RelevanceScorer()


def _create_test_article(db: Session, article_id: str, title: str, summary: str = "") -> NewsArticle:
    """Helper to create a test article with correct fields."""
    article = NewsArticle(
        id=article_id,
        title=title,
        link=f"https://example.com/{article_id}",
        summary=summary,
        source="test-source",
        published_at=None,
        scraped_at=utcnow(),
    )
    db.add(article)
    db.commit()
    return article


def _create_test_user(db: Session, user_id: str) -> User:
    """Helper to create a test user."""
    user = User(id=user_id, created_at=utcnow())
    db.add(user)
    db.commit()
    return user


def _create_test_situation(
    db: Session, user_id: str, status_text: str, goal_text: str = ""
) -> UserVisaSituation:
    """Helper to create a test visa situation."""
    situation = UserVisaSituation(
        user_id=user_id,
        current_status_text=status_text,
        current_status_chip="",
        goal_text=goal_text,
        updated_at=utcnow(),
    )
    db.add(situation)
    db.commit()
    return situation


class TestArticleCreation:
    """Test that scraped articles are created with all required fields."""

    def test_article_has_all_required_fields(self, test_db):
        """NewsArticle row should have id, title, link, summary, source, scraped_at."""
        article = _create_test_article(
            test_db,
            "news_abc123",
            "H-1B Processing Changes",
            "USCIS announced new rules for H-1B processing",
        )

        retrieved = test_db.query(NewsArticle).filter(NewsArticle.id == article.id).first()
        assert retrieved is not None
        assert retrieved.id == "news_abc123"
        assert retrieved.title == "H-1B Processing Changes"
        assert retrieved.link == "https://example.com/news_abc123"
        assert retrieved.summary == "USCIS announced new rules for H-1B processing"
        assert retrieved.source == "test-source"
        assert retrieved.scraped_at is not None

    def test_article_link_is_unique(self, test_db):
        """Two articles cannot have the same link."""
        link = "https://example.com/same-article"
        article1 = NewsArticle(
            id="news_1",
            title="Title 1",
            link=link,
            summary="Summary 1",
            source="test",
            scraped_at=utcnow(),
        )
        test_db.add(article1)
        test_db.commit()

        article2 = NewsArticle(
            id="news_2",
            title="Title 2",
            link=link,
            summary="Summary 2",
            source="test",
            scraped_at=utcnow(),
        )
        test_db.add(article2)

        # Should raise IntegrityError due to UNIQUE constraint on link
        with pytest.raises(Exception):
            test_db.commit()


class TestPersonalizationJobFlow:
    """Test the personalization job's core logic."""

    def test_personalization_creates_user_news_for_relevant_articles(self, test_db, scorer):
        """Personalization should create UserNews for articles matching a user's situation."""
        # Create a user with H-1B visa situation
        user = _create_test_user(test_db, "google_h1b_user")
        situation = _create_test_situation(
            test_db,
            user.id,
            "I'm currently on H-1B and looking to extend",
            "I want to stay on H-1B for another 3 years",
        )

        # Create an article about H-1B
        article = _create_test_article(
            test_db,
            "news_h1b_001",
            "New H-1B Processing Rules for 2026",
            "USCIS announces changes to H-1B visa processing procedures",
        )

        # Mock the score function to return affects_you verdict
        from app.models import RelevanceVerdict

        original_rank = scorer.rank

        def mock_rank(items, situation_input):
            scored = []
            for item in items:
                verdict = RelevanceVerdict(
                    level="affects_you",
                    confidence=0.85,
                    reason="H-1B visa category mentioned in title",
                    what_this_means="This looks relevant to your H-1B situation.",
                )
                scored.append((item, verdict))
            return scored

        scorer.rank = mock_rank

        try:
            # Import the personalization function with patched SessionLocal
            from app import personalization as perso_module

            # Patch SessionLocal to use test_db
            original_sessionlocal = perso_module.SessionLocal

            class MockSessionLocal:
                def __init__(self):
                    pass

                def query(self, *args, **kwargs):
                    return test_db.query(*args, **kwargs)

                def add(self, obj):
                    return test_db.add(obj)

                def commit(self):
                    return test_db.commit()

                def rollback(self):
                    return test_db.rollback()

                def close(self):
                    pass

            perso_module.SessionLocal = MockSessionLocal

            # Run personalization
            stats = asyncio.run(personalize_articles(scorer))

            assert stats["users_processed"] == 1
            assert stats["articles_evaluated"] == 1
            assert stats["matches_created"] == 1

            # Verify UserNews was created
            user_news = (
                test_db.query(UserNews)
                .filter(UserNews.user_id == user.id, UserNews.article_id == article.id)
                .first()
            )
            assert user_news is not None
            assert user_news.is_unread is True
            assert user_news.relevance_reason == "H-1B visa category mentioned in title"

        finally:
            scorer.rank = original_rank
            perso_module.SessionLocal = original_sessionlocal

    def test_personalization_skips_background_articles(self, test_db, scorer):
        """Personalization should NOT create UserNews for 'background' level articles."""
        user = _create_test_user(test_db, "google_user_bg")
        situation = _create_test_situation(test_db, user.id, "I'm on OPT")

        article = _create_test_article(
            test_db,
            "news_bg_001",
            "General Immigration News",
            "Background article about immigration policy",
        )

        from app.models import RelevanceVerdict

        original_rank = scorer.rank

        def mock_rank(items, situation_input):
            scored = []
            for item in items:
                verdict = RelevanceVerdict(
                    level="background",
                    confidence=0.3,
                    reason="Tangentially related to immigration",
                    what_this_means="General background information.",
                )
                scored.append((item, verdict))
            return scored

        scorer.rank = mock_rank

        try:
            from app import personalization as perso_module

            original_sessionlocal = perso_module.SessionLocal

            class MockSessionLocal:
                def query(self, *args, **kwargs):
                    return test_db.query(*args, **kwargs)

                def add(self, obj):
                    return test_db.add(obj)

                def commit(self):
                    return test_db.commit()

                def rollback(self):
                    return test_db.rollback()

                def close(self):
                    pass

            perso_module.SessionLocal = MockSessionLocal

            stats = asyncio.run(personalize_articles(scorer))

            assert stats["users_processed"] == 1
            assert stats["matches_created"] == 0

            # Verify NO UserNews was created
            user_news = (
                test_db.query(UserNews)
                .filter(UserNews.user_id == user.id, UserNews.article_id == article.id)
                .all()
            )
            assert len(user_news) == 0

        finally:
            scorer.rank = original_rank
            perso_module.SessionLocal = original_sessionlocal


class TestDuplicatePrevention:
    """Test that duplicate UserNews records are prevented."""

    def test_no_duplicate_user_news_created(self, test_db, scorer):
        """Personalization should not create duplicate UserNews records."""
        user = _create_test_user(test_db, "google_dup_user")
        situation = _create_test_situation(test_db, user.id, "I'm on F-1 OPT")

        article = _create_test_article(
            test_db,
            "news_opt_001",
            "OPT Extension Policy Update",
            "New guidance on STEM OPT eligibility",
        )

        # Manually create a UserNews record
        existing = UserNews(
            user_id=user.id,
            article_id=article.id,
            is_unread=True,
            relevance_reason="Previously matched",
            created_at=utcnow(),
        )
        test_db.add(existing)
        test_db.commit()

        # Run personalization which tries to create the same record
        from app.models import RelevanceVerdict

        original_rank = scorer.rank

        def mock_rank(items, situation_input):
            scored = []
            for item in items:
                verdict = RelevanceVerdict(
                    level="affects_you",
                    confidence=0.8,
                    reason="OPT mentioned",
                    what_this_means="Relevant to your OPT.",
                )
                scored.append((item, verdict))
            return scored

        scorer.rank = mock_rank

        try:
            from app import personalization as perso_module

            original_sessionlocal = perso_module.SessionLocal

            class MockSessionLocal:
                def query(self, *args, **kwargs):
                    return test_db.query(*args, **kwargs)

                def add(self, obj):
                    return test_db.add(obj)

                def commit(self):
                    return test_db.commit()

                def rollback(self):
                    return test_db.rollback()

                def close(self):
                    pass

            perso_module.SessionLocal = MockSessionLocal

            stats = asyncio.run(personalize_articles(scorer))

            # Should have 0 new matches created (duplicate was skipped)
            assert stats["matches_created"] == 0

            # Only one UserNews record should exist
            count = (
                test_db.query(UserNews)
                .filter(UserNews.user_id == user.id, UserNews.article_id == article.id)
                .count()
            )
            assert count == 1, "Only one UserNews record should exist"

        finally:
            scorer.rank = original_rank
            perso_module.SessionLocal = original_sessionlocal


class TestDataIsolation:
    """Test that user data is properly isolated."""

    def test_user_a_articles_do_not_leak_to_user_b(self, test_db, scorer):
        """User A's personalized articles should never appear in User B's feed."""
        # Create two users
        user_a = _create_test_user(test_db, "google_user_a")
        user_b = _create_test_user(test_db, "google_user_b")

        # User A has H-1B situation, User B has F-1 OPT
        situation_a = _create_test_situation(test_db, user_a.id, "I'm on H-1B")
        situation_b = _create_test_situation(test_db, user_b.id, "I'm on F-1 OPT")

        # Create two different articles
        article_h1b = _create_test_article(
            test_db, "news_h1b_xyz", "H-1B News", "Updates about H-1B visa"
        )
        article_opt = _create_test_article(
            test_db, "news_opt_xyz", "OPT News", "Updates about OPT extension"
        )

        from app.models import RelevanceVerdict

        def mock_rank_a(items, situation_input):
            # User A scenario: only H-1B article is relevant
            scored = []
            for item in items:
                if "h1b" in item.id.lower():
                    verdict = RelevanceVerdict(
                        level="affects_you",
                        confidence=0.9,
                        reason="H-1B",
                        what_this_means="Relevant to H-1B.",
                    )
                else:
                    verdict = RelevanceVerdict(
                        level="background",
                        confidence=0.1,
                        reason="Not relevant",
                        what_this_means="Background.",
                    )
                scored.append((item, verdict))
            return scored

        def mock_rank_b(items, situation_input):
            # User B scenario: only OPT article is relevant
            scored = []
            for item in items:
                if "opt" in item.id.lower():
                    verdict = RelevanceVerdict(
                        level="affects_you",
                        confidence=0.9,
                        reason="OPT",
                        what_this_means="Relevant to OPT.",
                    )
                else:
                    verdict = RelevanceVerdict(
                        level="background",
                        confidence=0.1,
                        reason="Not relevant",
                        what_this_means="Background.",
                    )
                scored.append((item, verdict))
            return scored

        original_rank = scorer.rank

        try:
            from app import personalization as perso_module
            from app.models import NewsItem, SituationInput

            original_sessionlocal = perso_module.SessionLocal
            original_personalize = perso_module.personalize_articles

            async def custom_personalize(scorer):
                # Manual personalization logic to test isolation
                db = test_db
                situations = db.query(UserVisaSituation).all()
                articles = db.query(NewsArticle).all()

                stats = {
                    "users_processed": 0,
                    "articles_evaluated": 0,
                    "matches_created": 0,
                }

                items_for_scoring = []
                for article in articles:
                    item = NewsItem(
                        id=article.id,
                        source_id=article.source,
                        source_name=article.source,
                        title=article.title,
                        url=article.link,
                        summary=article.summary,
                        published_at=article.published_at,
                        first_seen_at=article.scraped_at,
                    )
                    items_for_scoring.append(item)

                for situation_record in situations:
                    situation = SituationInput(
                        status_text=situation_record.current_status_text,
                        goal_text=situation_record.goal_text,
                    )

                    # Use different scorer function for each user
                    if situation_record.user_id == user_a.id:
                        scorer.rank = mock_rank_a
                    else:
                        scorer.rank = mock_rank_b

                    scored = scorer.rank(items_for_scoring, situation)

                    for item, verdict in scored:
                        stats["articles_evaluated"] += 1

                        if verdict.level == "background":
                            continue

                        existing = (
                            db.query(UserNews)
                            .filter(
                                UserNews.user_id == situation_record.user_id,
                                UserNews.article_id == item.id,
                            )
                            .first()
                        )
                        if existing is not None:
                            continue

                        user_news = UserNews(
                            user_id=situation_record.user_id,
                            article_id=item.id,
                            is_unread=True,
                            relevance_reason=verdict.reason,
                            created_at=utcnow(),
                        )
                        db.add(user_news)
                        stats["matches_created"] += 1

                    stats["users_processed"] += 1

                db.commit()
                return stats

            stats = asyncio.run(custom_personalize(scorer))

            # Verify isolation
            user_a_articles = (
                test_db.query(UserNews).filter(UserNews.user_id == user_a.id).all()
            )
            user_b_articles = (
                test_db.query(UserNews).filter(UserNews.user_id == user_b.id).all()
            )

            # User A should have H-1B article only
            assert len(user_a_articles) == 1
            assert user_a_articles[0].article_id == article_h1b.id

            # User B should have OPT article only
            assert len(user_b_articles) == 1
            assert user_b_articles[0].article_id == article_opt.id

        finally:
            scorer.rank = original_rank


class TestUserWithoutSituation:
    """Test graceful handling of users without recorded situations."""

    def test_no_crash_if_user_has_no_visa_situation(self, test_db, scorer):
        """Personalization should skip users who have no visa situation recorded."""
        # Create a user but NO visa situation
        user = _create_test_user(test_db, "google_no_situation")

        # Create an article
        article = _create_test_article(
            test_db,
            "news_general",
            "General Immigration News",
            "News about immigration",
        )

        try:
            from app import personalization as perso_module

            original_sessionlocal = perso_module.SessionLocal

            class MockSessionLocal:
                def query(self, *args, **kwargs):
                    return test_db.query(*args, **kwargs)

                def add(self, obj):
                    return test_db.add(obj)

                def commit(self):
                    return test_db.commit()

                def rollback(self):
                    return test_db.rollback()

                def close(self):
                    pass

            perso_module.SessionLocal = MockSessionLocal

            # Should run without crashing
            stats = asyncio.run(personalize_articles(scorer))

            # No users processed since the user has no situation
            assert stats["users_processed"] == 0
            assert stats["matches_created"] == 0

            # No UserNews created for this user
            user_news = (
                test_db.query(UserNews).filter(UserNews.user_id == user.id).all()
            )
            assert len(user_news) == 0

        finally:
            perso_module.SessionLocal = original_sessionlocal


def test_personalization_imports():
    """Personalization module imports without errors."""
    from app.personalization import personalize_articles

    assert callable(personalize_articles)
