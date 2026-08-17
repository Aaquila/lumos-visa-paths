"""Tests for the authenticated user pipeline: sign-in, situation, article sync.

Unlike `test_user_news.py`, these deliberately do NOT override the
`required_user` dependency — the whole point is to exercise the real
`db.query(User).filter(User.id == subject)` path (previously
`User.sub`, a column that doesn't exist, which made every one of these
endpoints crash) and the auto-registration it now does on a first valid
token. Tokens are minted locally and verified for real, mirroring the
`signed` fixture in `test_relevance.py`.
"""

from __future__ import annotations

import time

import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
import jwt as pyjwt
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy.pool import StaticPool

from app import main as api
from app.database import Base, NewsArticle, User, UserNews, UserVisaSituation, utcnow
from app.models import NewsItem
from app.personalization import sync_scraped_articles


CLIENT_ID = "123456789012-testclient.apps.googleusercontent.com"


@pytest.fixture()
def test_db():
    # StaticPool (one connection, shared) rather than the default per-thread
    # pool: `required_user`'s own `Depends(get_db)` and the endpoint's each
    # resolve independently, and FastAPI's TestClient runs the app on its own
    # anyio portal thread — without StaticPool that thread's first checkout
    # opens a *second*, separate, tableless `:memory:` database.
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    TestSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    db = TestSessionLocal()
    yield db
    db.close()


@pytest.fixture()
def client(test_db):
    from app.main import get_db

    def override_get_db():
        return test_db

    api.app.dependency_overrides[get_db] = override_get_db
    with TestClient(api.app) as test_client:
        yield test_client
    api.app.dependency_overrides.clear()


@pytest.fixture(scope="module")
def rsa_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture()
def signed(monkeypatch: pytest.MonkeyPatch, rsa_key):
    """Mint tokens signed by a local key, with the app trusting that key —
    same pattern as `test_relevance.py`."""
    monkeypatch.setattr(api, "GOOGLE_CLIENT_ID", CLIENT_ID)
    monkeypatch.setattr(api, "_signing_key", lambda token: rsa_key.public_key())

    def make(sub: str = "1029384756", **overrides) -> str:
        now = int(time.time())
        claims = {
            "iss": "https://accounts.google.com",
            "aud": CLIENT_ID,
            "sub": sub,
            "iat": now,
            "exp": now + 3600,
        }
        claims.update(overrides)
        return pyjwt.encode(claims, rsa_key, algorithm="RS256")

    return make


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


# ── required_user: real auth, not overridden ────────────────────────────────


class TestRequiredUserAutoRegisters:
    def test_first_valid_token_creates_a_user_row(self, client, test_db, signed):
        assert test_db.query(User).count() == 0

        response = client.get("/api/user/news/unread", headers=_auth(signed(sub="new-person")))

        assert response.status_code == 200
        stored = test_db.query(User).filter(User.id == "new-person").first()
        assert stored is not None
        assert stored.last_signin is not None

    def test_a_returning_token_reuses_the_row_and_bumps_last_signin(
        self, client, test_db, signed
    ):
        token = signed(sub="regular")
        client.get("/api/user/news/unread", headers=_auth(token))
        first_signin = test_db.query(User).filter(User.id == "regular").first().last_signin

        client.get("/api/user/news/unread", headers=_auth(signed(sub="regular")))

        assert test_db.query(User).filter(User.id == "regular").count() == 1
        second_signin = test_db.query(User).filter(User.id == "regular").first().last_signin
        assert second_signin >= first_signin

    def test_an_invalid_token_is_rejected_and_registers_nobody(self, client, test_db):
        response = client.get(
            "/api/user/news/unread", headers=_auth("not-a-real-token")
        )
        assert response.status_code == 401
        assert test_db.query(User).count() == 0

    def test_no_header_is_a_clean_401(self, client) -> None:
        response = client.get("/api/user/news/unread")
        assert response.status_code == 401


# ── POST/GET /api/user/situation ────────────────────────────────────────────


class TestSituationPersistence:
    def test_no_situation_recorded_yet(self, client, signed):
        response = client.get(
            "/api/user/situation", headers=_auth(signed(sub="fresh"))
        )
        assert response.status_code == 200
        body = response.json()
        assert body["has_situation"] is False
        assert body["status_text"] == ""

    def test_saving_then_reading_round_trips(self, client, test_db, signed):
        token = signed(sub="saver")
        response = client.post(
            "/api/user/situation",
            headers=_auth(token),
            json={
                "status_text": "I'm on an H-1B, software engineer",
                "goal_text": "Employer-sponsored green card",
            },
        )
        assert response.status_code == 200
        assert response.json()["status"] == "ok"

        record = (
            test_db.query(UserVisaSituation)
            .filter(UserVisaSituation.user_id == "saver")
            .first()
        )
        assert record is not None
        assert record.current_status_text == "I'm on an H-1B, software engineer"
        assert record.goal_text == "Employer-sponsored green card"

        fetched = client.get("/api/user/situation", headers=_auth(signed(sub="saver")))
        body = fetched.json()
        assert body["has_situation"] is True
        assert body["status_text"] == "I'm on an H-1B, software engineer"

    def test_saving_again_upserts_rather_than_duplicating(self, client, test_db, signed):
        user_sub = "editor"
        client.post(
            "/api/user/situation",
            headers=_auth(signed(sub=user_sub)),
            json={"status_text": "On F-1 OPT", "goal_text": ""},
        )
        client.post(
            "/api/user/situation",
            headers=_auth(signed(sub=user_sub)),
            json={"status_text": "Now on H-1B", "goal_text": "Green card"},
        )

        rows = (
            test_db.query(UserVisaSituation)
            .filter(UserVisaSituation.user_id == user_sub)
            .all()
        )
        assert len(rows) == 1
        assert rows[0].current_status_text == "Now on H-1B"

    def test_empty_status_text_is_rejected(self, client, signed):
        response = client.post(
            "/api/user/situation",
            headers=_auth(signed(sub="blank")),
            json={"status_text": "", "goal_text": ""},
        )
        assert response.status_code == 422


# ── sync_scraped_articles ────────────────────────────────────────────────────


class TestSyncScrapedArticles:
    def _item(self, **overrides) -> NewsItem:
        defaults = dict(
            id="news_abc123",
            source_id="fr_uscis",
            source_name="Federal Register — USCIS",
            title="A Rule About H-1B Filings",
            url="https://example.com/a-rule",
            summary="Some plain summary text.",
        )
        defaults.update(overrides)
        return NewsItem(**defaults)

    def test_empty_items_is_a_no_op(self):
        assert sync_scraped_articles([]) == 0

    def test_inserts_new_articles(self, test_db, monkeypatch):
        from app import personalization as perso_module

        monkeypatch.setattr(perso_module, "SessionLocal", lambda: test_db)
        # Prevent the fixture's own close() from firing mid-test via the
        # function's `finally: db.close()` — reopen isn't needed since the
        # in-memory engine is shared for the fixture's lifetime, but guard
        # against double-close raising.
        monkeypatch.setattr(test_db, "close", lambda: None)

        inserted = sync_scraped_articles([self._item()])

        assert inserted == 1
        row = test_db.query(NewsArticle).filter(NewsArticle.id == "news_abc123").first()
        assert row is not None
        assert row.title == "A Rule About H-1B Filings"
        assert row.link == "https://example.com/a-rule"

    def test_rerunning_with_the_same_item_does_not_duplicate(self, test_db, monkeypatch):
        from app import personalization as perso_module

        monkeypatch.setattr(perso_module, "SessionLocal", lambda: test_db)
        monkeypatch.setattr(test_db, "close", lambda: None)

        sync_scraped_articles([self._item()])
        second_pass_inserted = sync_scraped_articles(
            [self._item(title="A Slightly Revised Title")]
        )

        assert second_pass_inserted == 0
        assert test_db.query(NewsArticle).count() == 1
        row = test_db.query(NewsArticle).filter(NewsArticle.id == "news_abc123").first()
        assert row.title == "A Slightly Revised Title"

    def test_same_document_twice_in_one_batch_does_not_collide(
        self, test_db, monkeypatch
    ):
        """A real scrape can surface the same Federal Register document twice
        in one call — once per agency search that returns it (a joint
        DHS/State notice, say) — as two `NewsItem`s with different `id`s (the
        hash includes `source_id`) but the same `link`. Nothing is flushed
        between loop iterations, so without batch-local tracking both look
        "new" against the database and collide on the `link` unique
        constraint at commit — this reproduces exactly that against a real
        scrape's data before the fix (`IntegrityError: UNIQUE constraint
        failed: news_articles.link`)."""
        from app import personalization as perso_module

        monkeypatch.setattr(perso_module, "SessionLocal", lambda: test_db)
        monkeypatch.setattr(test_db, "close", lambda: None)

        same_link = "https://example.com/joint-notice"
        first = self._item(
            id="news_from_dhs_search",
            source_id="fr_dhs_immigration",
            title="Joint Notice",
            url=same_link,
        )
        second = self._item(
            id="news_from_state_search",
            source_id="fr_state_visa",
            title="Joint Notice",
            url=same_link,
        )

        inserted = sync_scraped_articles([first, second])

        assert inserted == 1
        assert test_db.query(NewsArticle).count() == 1
        row = test_db.query(NewsArticle).filter(NewsArticle.link == same_link).first()
        assert row.id == "news_from_dhs_search"  # first occurrence wins the row

    def test_a_title_change_that_shifts_the_id_matches_by_link_instead(
        self, test_db, monkeypatch
    ):
        """The id is a hash of source+url+title, so an edited title mints a
        new id — sync must still recognize this as the same article via its
        unique `link`, or it 500s on the link uniqueness constraint."""
        from app import personalization as perso_module

        monkeypatch.setattr(perso_module, "SessionLocal", lambda: test_db)
        monkeypatch.setattr(test_db, "close", lambda: None)

        sync_scraped_articles([self._item(id="news_original", title="Original Title")])
        inserted_again = sync_scraped_articles(
            [self._item(id="news_different_hash", title="Edited Title")]
        )

        assert inserted_again == 0
        assert test_db.query(NewsArticle).count() == 1
        row = test_db.query(NewsArticle).first()
        assert row.title == "Edited Title"
        assert row.id == "news_original"  # the FK-stable id is left alone


# ── End to end: sign in, save situation, sync, personalize, read it back ────


def test_end_to_end_personalized_match_is_visible(client, test_db, signed, monkeypatch):
    """The full chain this session's work depends on: a signed-in user with a
    saved situation actually sees a real match — not the public-feed fallback
    — once articles exist and personalization has run."""
    from app import personalization as perso_module
    from app.relevance import RelevanceScorer
    from app.models import RelevanceVerdict

    token = signed(sub="e2e-user")

    # 1. Sign in (auto-registers) and save a situation.
    client.get("/api/user/news/unread", headers=_auth(token))
    client.post(
        "/api/user/situation",
        headers=_auth(token),
        json={"status_text": "I'm on H-1B", "goal_text": "Green card"},
    )

    # 2. Sync a scraped item into NewsArticle.
    monkeypatch.setattr(perso_module, "SessionLocal", lambda: test_db)
    monkeypatch.setattr(test_db, "close", lambda: None)
    item = NewsItem(
        id="news_e2e",
        source_id="fr_uscis",
        source_name="Federal Register — USCIS",
        title="H-1B Rule Change",
        url="https://example.com/e2e",
        summary="A rule about H-1B processing.",
    )
    assert sync_scraped_articles([item]) == 1

    # 3. Run personalization with a scorer forced to call it relevant — the
    # deterministic scoring *rules* themselves are covered elsewhere
    # (test_relevance.py); this test is about the plumbing around them. Note
    # `personalize_articles` is called with a locally patched scorer, but the
    # `/api/user/news/all` endpoint re-scores with its own module-level
    # `relevance_scorer` via `refresh_relevance_levels` (by design — see that
    # function's docstring), so step 4 doesn't assume this level survives.
    scorer = RelevanceScorer()
    scorer.rank = lambda items, situation: [
        (
            i,
            RelevanceVerdict(
                level="affects_you",
                confidence=0.9,
                reason="H-1B mentioned",
                what_this_means="Relevant to your H-1B.",
            ),
        )
        for i in items
    ]
    import asyncio

    stats = asyncio.run(perso_module.personalize_articles(scorer))
    assert stats["matches_created"] == 1

    # 4. The authenticated endpoint now returns the real match, not an
    # empty/fallback response.
    response = client.get("/api/user/news/all", headers=_auth(token))
    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 1
    assert body["articles"][0]["article_id"] == "news_e2e"
    assert body["articles"][0]["relevance_level"] in ("affects_you", "worth_knowing")
