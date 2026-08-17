"""Tests for personalized news endpoints.

Tests the user-facing API endpoints for reading personalized news:
- GET /api/user/news/unread
- GET /api/user/news/all
- POST /api/user/news/:article_id/read

These endpoints require authentication and test both the happy path and error cases.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session

from app.database import Base, User, NewsArticle, UserNews, utcnow
from app.main import app


@pytest.fixture()
def test_db():
    """Create an in-memory SQLite database for testing."""
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
    )
    # Create tables
    Base.metadata.create_all(engine)
    TestSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    db = TestSessionLocal()
    yield db
    db.close()


@pytest.fixture()
def client(test_db):
    """Create a FastAPI test client with a mock database."""
    # Patch the get_db dependency
    from app.main import get_db

    def override_get_db():
        return test_db

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


def _create_test_user(db: Session, user_id: str) -> User:
    """Helper to create a test user."""
    user = User(id=user_id, created_at=utcnow())
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def _create_test_article(
    db: Session, article_id: str, title: str, link: str, summary: str = ""
) -> NewsArticle:
    """Helper to create a test article."""
    article = NewsArticle(
        id=article_id,
        title=title,
        link=link,
        summary=summary,
        source="test-source",
        published_at=None,
        scraped_at=utcnow(),
    )
    db.add(article)
    db.commit()
    db.refresh(article)
    return article


def _create_user_news(
    db: Session, user_id: str, article_id: str, is_unread: bool = True
) -> UserNews:
    """Helper to create a UserNews record."""
    user_news = UserNews(
        user_id=user_id,
        article_id=article_id,
        is_unread=is_unread,
        created_at=utcnow(),
    )
    db.add(user_news)
    db.commit()
    db.refresh(user_news)
    return user_news


def _make_auth_header(token: str) -> dict:
    """Helper to create an Authorization header."""
    return {"Authorization": f"Bearer {token}"}


class TestAuthenticationRequirements:
    """Test authentication for personalized news endpoints."""

    def test_unread_endpoint_requires_auth(self, client):
        """GET /api/user/news/unread should return 401 without token."""
        response = client.get("/api/user/news/unread")
        assert response.status_code == 401

    def test_all_endpoint_requires_auth(self, client):
        """GET /api/user/news/all should return 401 without token."""
        response = client.get("/api/user/news/all")
        assert response.status_code == 401

    def test_read_endpoint_requires_auth(self, client):
        """POST /api/user/news/:article_id/read should return 401 without token."""
        response = client.post("/api/user/news/1/read")
        assert response.status_code == 401

    def test_invalid_auth_header_format(self, client):
        """Invalid Authorization header format should return 401."""
        response = client.get(
            "/api/user/news/unread",
            headers={"Authorization": "InvalidFormat token"},
        )
        assert response.status_code == 401

    def test_missing_bearer_scheme(self, client):
        """Missing 'Bearer' scheme should return 401."""
        response = client.get(
            "/api/user/news/unread",
            headers={"Authorization": "some_random_token"},
        )
        assert response.status_code == 401


class TestUnreadNewsEndpoint:
    """Test GET /api/user/news/unread endpoint."""

    def test_returns_only_unread_articles(self, client, test_db):
        """Should return only articles where is_unread=true."""
        # Create user and articles
        user = _create_test_user(test_db, "google_sub_unread_test")
        article1 = _create_test_article(test_db, "hash1", "Unread Article 1", "link1")
        article2 = _create_test_article(test_db, "hash2", "Read Article", "link2")
        article3 = _create_test_article(test_db, "hash3", "Unread Article 2", "link3")

        # Create UserNews: 2 unread, 1 read
        _create_user_news(test_db, user.id, article1.id, is_unread=True)
        _create_user_news(test_db, user.id, article2.id, is_unread=False)
        _create_user_news(test_db, user.id, article3.id, is_unread=True)

        # Note: Since we're using a mock database without proper token verification,
        # we need to patch the required_user dependency as well
        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.get("/api/user/news/unread")
            assert response.status_code == 200

            data = response.json()
            assert data["count"] == 2
            assert len(data["articles"]) == 2

            # Verify the articles are the unread ones
            titles = [a["title"] for a in data["articles"]]
            assert "Unread Article 1" in titles
            assert "Unread Article 2" in titles
            assert "Read Article" not in titles

        finally:
            app.dependency_overrides.clear()

    def test_returns_correct_response_format(self, client, test_db):
        """Response should match UnreadNewsFeedResponse schema."""
        user = _create_test_user(test_db, "google_sub_format_test")
        article = _create_test_article(
            test_db, "hash_fmt", "Test Article", "https://example.com/test"
        )
        _create_user_news(test_db, user.id, article.id, is_unread=True)

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.get("/api/user/news/unread")
            assert response.status_code == 200

            data = response.json()
            assert "articles" in data
            assert "count" in data
            assert isinstance(data["count"], int)
            assert isinstance(data["articles"], list)

            if data["articles"]:
                article_obj = data["articles"][0]
                assert "article_id" in article_obj
                assert "title" in article_obj
                assert "link" in article_obj
                assert "summary" in article_obj
                assert "is_unread" in article_obj

        finally:
            app.dependency_overrides.clear()


class TestAllNewsEndpoint:
    """Test GET /api/user/news/all endpoint."""

    def test_returns_both_read_and_unread(self, client, test_db):
        """Should return all articles regardless of read status."""
        user = _create_test_user(test_db, "google_sub_all_test")
        article1 = _create_test_article(test_db, "hash_all_1", "Article 1", "link1")
        article2 = _create_test_article(test_db, "hash_all_2", "Article 2", "link2")
        article3 = _create_test_article(test_db, "hash_all_3", "Article 3", "link3")

        # Create UserNews with mixed read status
        _create_user_news(test_db, user.id, article1.id, is_unread=True)
        _create_user_news(test_db, user.id, article2.id, is_unread=False)
        _create_user_news(test_db, user.id, article3.id, is_unread=True)

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.get("/api/user/news/all")
            assert response.status_code == 200

            data = response.json()
            assert data["total"] == 3
            assert len(data["articles"]) == 3

        finally:
            app.dependency_overrides.clear()

    def test_pagination_limit_and_offset(self, client, test_db):
        """Should respect limit and offset parameters."""
        user = _create_test_user(test_db, "google_sub_pagination_test")

        # Create 25 articles
        articles = []
        for i in range(25):
            article = _create_test_article(
                test_db, f"hash_page_{i}", f"Article {i}", f"link_{i}"
            )
            articles.append(article)
            _create_user_news(test_db, user.id, article.id, is_unread=True)

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            # Test limit=10, offset=0
            response = client.get("/api/user/news/all?limit=10&offset=0")
            assert response.status_code == 200
            data = response.json()
            assert data["total"] == 25
            assert data["limit"] == 10
            assert data["offset"] == 0
            assert len(data["articles"]) == 10

            # Test limit=10, offset=20
            response = client.get("/api/user/news/all?limit=10&offset=20")
            assert response.status_code == 200
            data = response.json()
            assert len(data["articles"]) == 5  # Only 5 left after offset
            assert data["offset"] == 20

        finally:
            app.dependency_overrides.clear()

    def test_pagination_limit_bounds(self, client, test_db):
        """Limit should be bounded by min and max."""
        user = _create_test_user(test_db, "google_sub_bounds_test")

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            # Test limit=0 (should be rejected as < 1)
            response = client.get("/api/user/news/all?limit=0")
            assert response.status_code == 422

            # Test limit=101 (should be rejected as > 100)
            response = client.get("/api/user/news/all?limit=101")
            assert response.status_code == 422

        finally:
            app.dependency_overrides.clear()


class TestMarkNewsAsReadEndpoint:
    """Test POST /api/user/news/:article_id/read endpoint."""

    def test_marks_article_as_read(self, client, test_db):
        """Should set is_unread=false and marked_read_at=now()."""
        user = _create_test_user(test_db, "google_sub_read_test")
        article = _create_test_article(
            test_db, "hash_read", "Article to Read", "link_read"
        )
        user_news = _create_user_news(test_db, user.id, article.id, is_unread=True)

        assert user_news.is_unread is True
        assert user_news.marked_read_at is None

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.post(f"/api/user/news/{article.id}/read")
            assert response.status_code == 200

            data = response.json()
            assert data["status"] == "ok"
            assert data["marked_read_at"] is not None

            # Verify in database
            updated = test_db.query(UserNews).filter(UserNews.id == user_news.id).first()
            assert updated.is_unread is False
            assert updated.marked_read_at is not None

        finally:
            app.dependency_overrides.clear()

    def test_returns_404_for_nonexistent_article(self, client, test_db):
        """Should return 404 if article doesn't exist for this user."""
        user = _create_test_user(test_db, "google_sub_404_test")

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.post("/api/user/news/999/read")
            assert response.status_code == 404

        finally:
            app.dependency_overrides.clear()

    def test_cross_user_protection(self, client, test_db):
        """User should not be able to mark another user's article as read."""
        user_a = _create_test_user(test_db, "google_sub_a")
        user_b = _create_test_user(test_db, "google_sub_b")

        article = _create_test_article(test_db, "hash_cross", "Article", "link_cross")

        # Article belongs to user_b only
        user_b_news = _create_user_news(test_db, user_b.id, article.id, is_unread=True)

        from app.main import required_user

        def override_required_user():
            return user_a

        app.dependency_overrides[required_user] = override_required_user

        try:
            # user_a tries to mark user_b's article as read
            response = client.post(f"/api/user/news/{article.id}/read")
            assert response.status_code == 404

            # Verify user_b's article is still unread
            updated = test_db.query(UserNews).filter(UserNews.id == user_b_news.id).first()
            assert updated.is_unread is True

        finally:
            app.dependency_overrides.clear()

    def test_response_format(self, client, test_db):
        """Response should match MarkReadResponse schema."""
        user = _create_test_user(test_db, "google_sub_resp_test")
        article = _create_test_article(test_db, "hash_resp", "Article", "link_resp")
        _create_user_news(test_db, user.id, article.id, is_unread=True)

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.post(f"/api/user/news/{article.id}/read")
            assert response.status_code == 200

            data = response.json()
            assert "status" in data
            assert "marked_read_at" in data
            assert data["status"] == "ok"
            assert isinstance(data["marked_read_at"], str)  # ISO datetime

        finally:
            app.dependency_overrides.clear()


class TestDataIsolation:
    """Test that endpoints enforce user data isolation."""

    def test_unread_news_only_shows_user_articles(self, client, test_db):
        """A user should only see their own unread articles."""
        user_a = _create_test_user(test_db, "google_sub_isolation_a")
        user_b = _create_test_user(test_db, "google_sub_isolation_b")

        article_a = _create_test_article(test_db, "hash_iso_a", "Article A", "link_a")
        article_b = _create_test_article(test_db, "hash_iso_b", "Article B", "link_b")

        # Create separate news items for each user
        _create_user_news(test_db, user_a.id, article_a.id, is_unread=True)
        _create_user_news(test_db, user_b.id, article_b.id, is_unread=True)

        from app.main import required_user

        def override_required_user():
            return user_a

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.get("/api/user/news/unread")
            assert response.status_code == 200

            data = response.json()
            assert data["count"] == 1
            assert len(data["articles"]) == 1
            assert data["articles"][0]["title"] == "Article A"

        finally:
            app.dependency_overrides.clear()

    def test_all_news_only_shows_user_articles(self, client, test_db):
        """A user should only see their own articles with GET /all."""
        user_a = _create_test_user(test_db, "google_sub_all_iso_a")
        user_b = _create_test_user(test_db, "google_sub_all_iso_b")

        article_a = _create_test_article(test_db, "hash_all_iso_a", "Article A", "link_a")
        article_b = _create_test_article(test_db, "hash_all_iso_b", "Article B", "link_b")

        _create_user_news(test_db, user_a.id, article_a.id, is_unread=False)
        _create_user_news(test_db, user_b.id, article_b.id, is_unread=False)

        from app.main import required_user

        def override_required_user():
            return user_a

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.get("/api/user/news/all")
            assert response.status_code == 200

            data = response.json()
            assert data["total"] == 1
            assert len(data["articles"]) == 1
            assert data["articles"][0]["title"] == "Article A"

        finally:
            app.dependency_overrides.clear()


class TestEmptyStates:
    """Test endpoints with no data."""

    def test_unread_returns_empty_list_when_no_unread(self, client, test_db):
        """Should return empty articles list when user has no unread news."""
        user = _create_test_user(test_db, "google_sub_empty_unread")
        article = _create_test_article(test_db, "hash_empty", "Article", "link_empty")

        # Article is read
        _create_user_news(test_db, user.id, article.id, is_unread=False)

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.get("/api/user/news/unread")
            assert response.status_code == 200

            data = response.json()
            assert data["count"] == 0
            assert len(data["articles"]) == 0

        finally:
            app.dependency_overrides.clear()

    def test_all_returns_empty_list_when_no_articles(self, client, test_db):
        """Should return empty articles list when user has no news."""
        user = _create_test_user(test_db, "google_sub_empty_all")

        from app.main import required_user

        def override_required_user():
            return user

        app.dependency_overrides[required_user] = override_required_user

        try:
            response = client.get("/api/user/news/all")
            assert response.status_code == 200

            data = response.json()
            assert data["total"] == 0
            assert len(data["articles"]) == 0

        finally:
            app.dependency_overrides.clear()
