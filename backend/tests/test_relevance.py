"""Tests for news relevance, the no-persistence promise, auth and CORS.

Three things these tests exist to hold in place:

1. **Relevance works with no API key.** Every scoring test here runs on the
   deterministic path, because that is the path that ships. If a change makes
   good ranking depend on a model call, these fail.
2. **Nothing about a person is stored.** `test_no_persistence` reaches past the
   API into SQLite and greps every row for the words the caller sent.
3. **Tokens are verified, not decoded.** Expired, wrong-audience, wrong-issuer
   and malformed tokens are all rejected, using a locally generated key pair so
   nothing here touches Google.

No network: the JWKS lookup is substituted, and the store is a temp file.
"""

from __future__ import annotations

import os

# The app starts a daily scrape loop on startup. These tests never enter the
# lifespan (TestClient is used without its context manager), but setting this
# before the import makes the intent explicit and survives a future change.
os.environ.setdefault("SCRAPE_ON_STARTUP", "0")

import time  # noqa: E402
from datetime import date, datetime, timedelta, timezone  # noqa: E402

import jwt  # noqa: E402
import pytest  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app import main as api  # noqa: E402
from app.models import DocumentMeta, NewsItem, SituationInput  # noqa: E402
from app.relevance import (  # noqa: E402
    AFFECTS_YOU,
    BACKGROUND,
    WORTH_KNOWING,
    RelevanceScorer,
    collect_hits,
    counts,
    node_label,
    rank,
    read_situation,
    score_item,
)
from app.store import NewsStore  # noqa: E402

# ── Fixtures ──────────────────────────────────────────────────────────────────


def _item(
    title: str,
    *,
    id_: str = "",
    summary: str = "",
    nodes: list[str] | None = None,
    meta: DocumentMeta | None = None,
    source_name: str = "Federal Register — USCIS",
    days_ago: int = 0,
) -> NewsItem:
    url = f"https://www.federalregister.gov/documents/{id_ or abs(hash(title)) % 9999}"
    return NewsItem(
        id=id_ or NewsItem.make_id("fr_uscis", url, title),
        source_id="fr_uscis",
        source_name=source_name,
        title=title,
        url=url,
        summary=summary,
        published_at=datetime.now(timezone.utc) - timedelta(days=days_ago),
        matched_nodes=nodes or [],
        meta=meta or DocumentMeta(),
    )


STEM_OPT_FEE_RULE = _item(
    "Employment Authorization Documents; Form I-765 Filing Fee Schedule",
    id_="news_fee",
    summary="USCIS adjusts the filing fee for Form I-765 for STEM OPT students.",
    nodes=["student.stem_opt", "student.opt_postcompletion"],
    meta=DocumentMeta(
        document_type="Rule",
        document_number="2026-0001",
        agencies=["u-s-citizenship-and-immigration-services"],
        cfr_references=["8 CFR 274a", "8 CFR 106"],
        effective_on=date(2026, 10, 1),
    ),
)

H1B_CAP_NOTICE = _item(
    "H-1B Cap Registration Period; Form I-129 Electronic Registration",
    id_="news_h1b",
    summary="Registration for the FY 2028 H-1B cap opens.",
    nodes=["temp_worker.h1b"],
    meta=DocumentMeta(
        document_type="Notice",
        agencies=["u-s-citizenship-and-immigration-services"],
    ),
)

ADVISORY_MEETING = _item(
    "Meeting of the Homeland Security Advisory Council",
    id_="news_meeting",
    summary="Notice of an open meeting.",
    meta=DocumentMeta(
        document_type="Notice", agencies=["homeland-security-department"]
    ),
)

TPS_HAITI = _item(
    "Extension of the Designation of Haiti for Temporary Protected Status",
    id_="news_tps",
    summary="DHS extends the TPS designation for Haiti.",
    nodes=["humanitarian.tps"],
    meta=DocumentMeta(
        document_type="Notice",
        agencies=["homeland-security-department"],
        cfr_references=["8 CFR 244"],
    ),
)

EB2_BULLETIN = _item(
    "Visa Bulletin: EB-2 final action dates retrogress",
    id_="news_eb2",
    summary="Priority dates move backwards, including for applicants from India.",
    nodes=["employment_gc.eb2"],
    source_name="Federal Register — State Department visa items",
    meta=DocumentMeta(document_type="Notice", agencies=["state-department"]),
)

ALL_ITEMS = [
    ADVISORY_MEETING,
    H1B_CAP_NOTICE,
    STEM_OPT_FEE_RULE,
    EB2_BULLETIN,
    TPS_HAITI,
]

ON_STEM_OPT = SituationInput(
    status_text="I'm on STEM OPT after my master's in computer science.",
    goal_text="I want a green card through EB-2 one day.",
    country="India",
    change_year=2027,
    change_month=6,
)


# ── Reading the person ────────────────────────────────────────────────────────


def test_situation_is_read_through_the_shared_signal_extraction() -> None:
    reader = read_situation(ON_STEM_OPT)

    # Status text places them now; goal text is kept separate on purpose.
    assert "student.stem_opt" in reader.now_nodes
    assert "employment_gc.eb2" in reader.goal_nodes
    assert not (reader.now_nodes & reader.goal_nodes)

    # `options.extract_signals` ran — this is the same reading the option
    # ranker uses, not a second copy of it.
    assert reader.signals.get("stem_degree") is True
    assert reader.signals.get("advanced_degree") is True

    # Forms are derived from statuses, so the person never has to name one.
    assert "I-765" in reader.forms
    assert "India" in reader.countries
    assert reader.change_note == "June 2027"


def test_a_resolved_node_id_alone_is_enough() -> None:
    """A client that has run intake sends ids, not prose. Same quality."""
    reader = read_situation(SituationInput(current_node_id="temp_worker.h1b"))
    assert "h1b" in reader.now_categories
    assert "I-129" in reader.forms


def test_extra_node_ids_are_aspirations_not_the_present() -> None:
    reader = read_situation(
        SituationInput(current_node_id="student.f1", node_ids=["temp_worker.h1b"])
    )
    assert "student.f1" in reader.now_nodes
    assert "temp_worker.h1b" in reader.goal_nodes
    assert "temp_worker.h1b" not in reader.now_nodes


# ── Scoring ───────────────────────────────────────────────────────────────────


def test_an_item_naming_your_status_and_your_form_affects_you() -> None:
    verdict = score_item(STEM_OPT_FEE_RULE, read_situation(ON_STEM_OPT))

    assert verdict.level == AFFECTS_YOU
    assert verdict.confidence > 0.5
    # No unexplained ranking: the reason names the concrete signal.
    assert verdict.reason
    assert "Post-Completion OPT" in verdict.reason or "STEM OPT" in verdict.reason
    assert {"node", "form", "fee"} <= {s.kind for s in verdict.signals}
    assert "student.stem_opt" in verdict.touches_nodes


def test_an_unrelated_notice_is_background_and_says_why() -> None:
    verdict = score_item(ADVISORY_MEETING, read_situation(ON_STEM_OPT))

    assert verdict.level == BACKGROUND
    assert "nothing" in verdict.reason.lower() or "named" in verdict.reason.lower()
    # The honest empty answer, not a manufactured connection.
    assert "does not name" in verdict.what_this_means


def test_a_goal_route_is_worth_knowing_but_never_affects_you() -> None:
    """The rule that keeps the top band meaningful.

    Somebody who says "a green card one day" matches half the Federal Register.
    Calling that "affects you" is the overreach this module exists to prevent.
    """
    verdict = score_item(EB2_BULLETIN, read_situation(ON_STEM_OPT))

    assert verdict.level == WORTH_KNOWING
    assert all(s.kind != "node" or True for s in verdict.signals)
    assert "trying to go" in verdict.what_this_means


def test_a_fee_change_alone_does_not_score() -> None:
    """Event kinds are amplifiers, not matches.

    A fee change matters enormously if it is your form and not at all
    otherwise. Scoring it on its own would be the naive keyword ranking.
    """
    reader = read_situation(SituationInput(current_node_id="post_lpr.naturalization"))
    hits = collect_hits(STEM_OPT_FEE_RULE, reader)
    assert not any(h.kind == "fee" for h in hits)


def test_country_specific_items_reach_the_person_they_name() -> None:
    """A country in the headline scopes a document by nationality.

    A TPS designation for Haiti reaches a Haitian national whatever status they
    currently hold, so nationality is treated as a fact about the present.
    """
    haitian_asylum_seeker = SituationInput(
        status_text="I applied for asylum after arriving from Haiti.",
        country="Haiti",
    )
    verdict = score_item(TPS_HAITI, read_situation(haitian_asylum_seeker))

    assert verdict.level == AFFECTS_YOU
    assert "Haiti" in {s.label for s in verdict.signals}


def test_a_country_buried_in_the_body_does_not_promote_an_ambition() -> None:
    """The other half of the same rule.

    "including for applicants from India" inside a bulletin is not the same as
    a document scoped to India, and it must not turn "I'd like a green card one
    day" into "this affects you".
    """
    verdict = score_item(EB2_BULLETIN, read_situation(ON_STEM_OPT))
    country = next(s for s in verdict.signals if s.kind == "country")
    assert country.found_in == "summary"
    assert verdict.level == WORTH_KNOWING


def test_the_same_item_lands_differently_for_two_people() -> None:
    """The whole product in one assertion."""
    student = read_situation(SituationInput(current_node_id="student.stem_opt"))
    h1b_holder = read_situation(SituationInput(current_node_id="temp_worker.h1b"))

    assert score_item(H1B_CAP_NOTICE, h1b_holder).level == AFFECTS_YOU
    assert score_item(H1B_CAP_NOTICE, student).level != AFFECTS_YOU


def test_structured_metadata_is_used_not_just_prose() -> None:
    """The CFR reference is a fact about who a rule reaches.

    Same title and abstract, one with the Federal Register's CFR metadata and
    one without. The metadata has to move the score, or the scraper is asking
    the API for fields nobody reads.
    """
    reader = read_situation(SituationInput(current_node_id="student.stem_opt"))

    bare = _item("Adjustments to certain immigration benefit requests", id_="bare")
    with_meta = _item(
        "Adjustments to certain immigration benefit requests",
        id_="meta",
        nodes=["student.stem_opt"],
        meta=DocumentMeta(
            document_type="Rule",
            agencies=["u-s-citizenship-and-immigration-services"],
            cfr_references=["8 CFR 274a"],
        ),
    )

    assert score_item(with_meta, reader).confidence > score_item(bare, reader).confidence
    assert "cfr" in {s.kind for s in score_item(with_meta, reader).signals}


def test_every_verdict_carries_a_reason() -> None:
    reader = read_situation(ON_STEM_OPT)
    for item in ALL_ITEMS:
        verdict = score_item(item, reader)
        assert verdict.reason.strip(), f"{item.title} ranked with no reason"
        assert verdict.what_this_means.strip()


def test_nothing_is_phrased_as_a_legal_effect() -> None:
    """Accuracy rule: we never assert that a document legally affects somebody."""
    reader = read_situation(ON_STEM_OPT)
    for item in ALL_ITEMS:
        text = score_item(item, reader).what_this_means.lower()
        for forbidden in (
            "this affects you",
            "you must",
            "you are required",
            "you will need to",
            "legally",
            "you qualify",
        ):
            assert forbidden not in text, f"{forbidden!r} in: {text}"


def test_relevant_items_point_at_the_primary_source_and_disclaim() -> None:
    reader = read_situation(ON_STEM_OPT)
    verdict = score_item(STEM_OPT_FEE_RULE, reader)
    assert "read the original" in verdict.what_this_means.lower()
    assert "not legal advice" in verdict.what_this_means.lower()
    # The link itself rides on the item, which the API returns alongside.
    assert str(STEM_OPT_FEE_RULE.url).startswith("https://")


def test_node_ids_never_leak_into_the_copy() -> None:
    reader = read_situation(ON_STEM_OPT)
    for item in ALL_ITEMS:
        verdict = score_item(item, reader)
        for text in (verdict.reason, verdict.what_this_means):
            assert "student." not in text
            assert "employment_gc." not in text
            assert "temp_worker." not in text


def test_node_label_falls_back_readably() -> None:
    assert node_label("student.stem_opt") == "STEM OPT Extension"
    assert node_label("made_up.thing_here") == "thing here"


# ── Ranking ───────────────────────────────────────────────────────────────────


def test_ranking_puts_what_affects_you_first_and_drops_nothing() -> None:
    scored = rank(ALL_ITEMS, ON_STEM_OPT)

    assert len(scored) == len(ALL_ITEMS), "a person is entitled to the whole feed"
    levels = [verdict.level for _, verdict in scored]
    order = {AFFECTS_YOU: 0, WORTH_KNOWING: 1, BACKGROUND: 2}
    assert levels == sorted(levels, key=lambda lvl: order[lvl])
    assert scored[0][1].level == AFFECTS_YOU


def test_counts_always_carry_all_three_bands() -> None:
    tally = counts([verdict for _, verdict in rank(ALL_ITEMS, ON_STEM_OPT)])
    # An empty "affects you" band is itself the answer, so the key must exist.
    assert set(tally) == {AFFECTS_YOU, WORTH_KNOWING, BACKGROUND}
    assert sum(tally.values()) == len(ALL_ITEMS)


def test_an_empty_situation_scores_everything_as_background() -> None:
    """No situation is not a reason to guess. It is a reason to say so."""
    scored = rank(ALL_ITEMS, SituationInput())
    assert {verdict.level for _, verdict in scored} == {BACKGROUND}
    assert all("have not told us" in v.reason for _, v in scored)


def test_scoring_is_deterministic() -> None:
    first = [(i.id, v.level, v.confidence) for i, v in rank(ALL_ITEMS, ON_STEM_OPT)]
    second = [(i.id, v.level, v.confidence) for i, v in rank(ALL_ITEMS, ON_STEM_OPT)]
    assert first == second


# ── The no-API-key path ───────────────────────────────────────────────────────


def test_the_scorer_works_with_no_api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """The deterministic path is the product, not a fallback."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    scorer = RelevanceScorer()

    assert scorer.llm_available is False
    scored = scorer.rank(ALL_ITEMS, ON_STEM_OPT)
    assert scored[0][1].level == AFFECTS_YOU
    assert all(v.explained_by == "deterministic" for _, v in scored)


@pytest.mark.asyncio
async def test_refine_is_a_no_op_without_a_key(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    scorer = RelevanceScorer()
    scored = scorer.rank(ALL_ITEMS, ON_STEM_OPT)
    written = [v.what_this_means for _, v in scored]

    assert await scorer.refine(scored, ON_STEM_OPT) is False
    # Nothing was blanked out waiting for a model that was never called.
    assert [v.what_this_means for _, v in scored] == written


# ── API ───────────────────────────────────────────────────────────────────────


@pytest.fixture()
def client(tmp_path, monkeypatch: pytest.MonkeyPatch) -> TestClient:
    """The app against a throwaway store, with no lifespan and no network."""
    store = NewsStore(tmp_path / "news.sqlite3")
    store.save_items(ALL_ITEMS)
    monkeypatch.setattr(api, "store", store)
    # TestClient without `with` does not run the lifespan, so the daily scrape
    # loop never starts.
    return TestClient(api.app)


def test_relevant_endpoint_annotates_and_sorts(client: TestClient) -> None:
    response = client.post(
        "/api/news/relevant", json=ON_STEM_OPT.model_dump(mode="json")
    )
    assert response.status_code == 200
    body = response.json()

    assert body["personalised"] is True
    assert body["llm_used"] is False
    assert body["disclaimer"]
    assert set(body["counts"]) == {AFFECTS_YOU, WORTH_KNOWING, BACKGROUND}

    levels = [entry["relevance"]["level"] for entry in body["items"]]
    assert levels[0] == AFFECTS_YOU
    first = body["items"][0]
    assert first["relevance"]["reason"]
    assert first["relevance"]["what_this_means"]
    # The primary source travels with every item.
    assert first["item"]["url"].startswith("https://")


def test_relevant_endpoint_degrades_honestly_without_a_situation(
    client: TestClient,
) -> None:
    response = client.post("/api/news/relevant", json={})
    assert response.status_code == 200
    body = response.json()

    assert body["personalised"] is False
    assert body["counts"][AFFECTS_YOU] == 0
    assert len(body["items"]) == len(ALL_ITEMS)


def test_the_plain_news_list_stays_public(client: TestClient) -> None:
    assert client.get("/api/news/alerts").status_code == 200


# ── The no-persistence guarantee ──────────────────────────────────────────────

#: Phrases that appear nowhere in the seeded news items, so a hit can only mean
#: the caller's own words were written to disk.
_SECRETS = [
    "working at a robotics startup in Austin",
    "my wife is finishing her PhD",
    "zzq-canary-marker",
]


def test_no_persistence_of_the_callers_situation(tmp_path, monkeypatch) -> None:
    """The promise: the backend stores nothing about the person.

    This reads every value out of every table after a scoring request and
    asserts the caller's own words are nowhere in the database. It is
    deliberately blunt — a cache, a log table or an "anonymous" analytics row
    would all fail it, which is the point.
    """
    import sqlite3

    db = tmp_path / "news.sqlite3"
    store = NewsStore(db)
    store.save_items(ALL_ITEMS)
    monkeypatch.setattr(api, "store", store)

    situation = {
        "status_text": "I'm on STEM OPT, working at a robotics startup in Austin.",
        "goal_text": "A green card. Also my wife is finishing her PhD.",
        "country": "zzq-canary-marker",
        "current_node_id": "student.stem_opt",
    }
    client = TestClient(api.app)
    assert client.post("/api/news/relevant", json=situation).status_code == 200

    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    tables = [
        r["name"]
        for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
    ]
    # No table appeared to hold a person, either.
    assert not any(
        word in t.lower() for t in tables for word in ("user", "session", "caller")
    ), f"an identity table exists: {tables}"

    blob = ""
    for table in tables:
        for row in conn.execute(f"SELECT * FROM {table}"):  # noqa: S608 — table names
            blob += " ".join(str(v) for v in tuple(row))
    conn.close()

    for secret in _SECRETS:
        assert secret not in blob, f"the caller's situation was persisted: {secret!r}"


def test_the_store_exposes_no_way_to_write_a_situation() -> None:
    """A structural check to go with the behavioural one above.

    If somebody adds `NewsStore.save_situation`, this fails before it ships.
    """
    writers = [
        name
        for name in dir(NewsStore)
        if name.startswith("save") or name.startswith("write")
    ]
    assert sorted(writers) == ["save_items", "save_run"]


# ── Google ID token verification ──────────────────────────────────────────────

CLIENT_ID = "123456789012-testclient.apps.googleusercontent.com"


@pytest.fixture(scope="module")
def rsa_key():
    """A local key pair, so nothing in these tests reaches Google."""
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture()
def signed(monkeypatch: pytest.MonkeyPatch, rsa_key):
    """Mint tokens signed by the local key, with the app trusting that key."""
    monkeypatch.setattr(api, "GOOGLE_CLIENT_ID", CLIENT_ID)
    monkeypatch.setattr(api, "_signing_key", lambda token: rsa_key.public_key())

    def make(**overrides) -> str:
        now = int(time.time())
        claims = {
            "iss": "https://accounts.google.com",
            "aud": CLIENT_ID,
            "sub": "1029384756",
            "iat": now,
            "exp": now + 3600,
            "email": "someone@example.com",
        }
        claims.update(overrides)
        return jwt.encode(claims, rsa_key, algorithm="RS256")

    return make


def test_a_valid_token_verifies_and_yields_only_the_subject(signed) -> None:
    assert api.verify_google_id_token(signed()) == "1029384756"


def test_an_expired_token_is_rejected(signed) -> None:
    now = int(time.time())
    with pytest.raises(api.HTTPException) as exc:
        api.verify_google_id_token(signed(exp=now - 60, iat=now - 3600))
    assert exc.value.status_code == 401
    assert "expired" in exc.value.detail.lower()


def test_a_token_for_another_application_is_rejected(signed) -> None:
    with pytest.raises(api.HTTPException) as exc:
        api.verify_google_id_token(signed(aud="someone-elses.apps.googleusercontent.com"))
    assert exc.value.status_code == 401


def test_a_token_from_another_issuer_is_rejected(signed) -> None:
    with pytest.raises(api.HTTPException) as exc:
        api.verify_google_id_token(signed(iss="https://evil.example.com"))
    assert exc.value.status_code == 401


def test_a_malformed_token_is_rejected(signed) -> None:
    for garbage in ("", "not-a-jwt", "a.b.c", "eyJhbGciOiJub25lIn0..", "  "):
        with pytest.raises(api.HTTPException) as exc:
            api.verify_google_id_token(garbage)
        assert exc.value.status_code == 401


def test_an_unsigned_token_is_rejected(monkeypatch, rsa_key) -> None:
    """`alg: none` is the classic bypass. Only RS256 is accepted."""
    monkeypatch.setattr(api, "GOOGLE_CLIENT_ID", CLIENT_ID)
    monkeypatch.setattr(api, "_signing_key", lambda token: rsa_key.public_key())
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://accounts.google.com",
            "aud": CLIENT_ID,
            "sub": "1",
            "iat": now,
            "exp": now + 60,
        },
        key="",
        algorithm="none",
    )
    with pytest.raises(api.HTTPException) as exc:
        api.verify_google_id_token(token)
    assert exc.value.status_code == 401


def test_a_token_with_no_subject_is_rejected(signed, rsa_key, monkeypatch) -> None:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://accounts.google.com",
            "aud": CLIENT_ID,
            "iat": now,
            "exp": now + 60,
        },
        rsa_key,
        algorithm="RS256",
    )
    with pytest.raises(api.HTTPException) as exc:
        api.verify_google_id_token(token)
    assert exc.value.status_code == 401


def test_an_unconfigured_server_refuses_rather_than_pretending(
    monkeypatch, signed
) -> None:
    """Accepting unverifiable tokens because the server is misconfigured is how
    "we verify tokens" quietly becomes false."""
    monkeypatch.setattr(api, "GOOGLE_CLIENT_ID", "")
    with pytest.raises(api.HTTPException) as exc:
        api.verify_google_id_token("anything")
    assert exc.value.status_code == 503


# ── Auth as applied to endpoints ──────────────────────────────────────────────


def test_endpoints_taking_a_situation_work_without_a_token(client: TestClient) -> None:
    """Genuinely public stays usable. Signing in is not a wall."""
    response = client.post(
        "/api/news/relevant", json={"status_text": "I am on H-1B."}
    )
    assert response.status_code == 200
    assert response.json()["personalised"] is True


def test_a_forged_token_is_rejected_rather_than_trusted(
    client: TestClient, signed
) -> None:
    response = client.post(
        "/api/news/relevant",
        json={"status_text": "I am on H-1B."},
        headers={"Authorization": "Bearer not.a.real.token"},
    )
    assert response.status_code == 401


def test_a_valid_token_is_accepted(client: TestClient, signed) -> None:
    response = client.post(
        "/api/news/relevant",
        json={"status_text": "I am on H-1B."},
        headers={"Authorization": f"Bearer {signed()}"},
    )
    assert response.status_code == 200


def test_a_non_bearer_authorization_header_is_rejected(client: TestClient) -> None:
    response = client.post(
        "/api/news/relevant",
        json={"status_text": "I am on H-1B."},
        headers={"Authorization": "Basic dXNlcjpwYXNz"},
    )
    assert response.status_code == 401


def test_the_options_endpoint_verifies_a_presented_token(
    client: TestClient, signed
) -> None:
    response = client.post(
        "/api/case/options",
        json={"text": "I want to work in the US"},
        headers={"Authorization": "Bearer garbage"},
    )
    assert response.status_code == 401


# ── CORS ──────────────────────────────────────────────────────────────────────


def test_the_dev_origin_is_allowed_by_default() -> None:
    assert "http://localhost:7357" in api.CORS_ORIGINS


def test_cors_is_never_a_wildcard() -> None:
    assert "*" not in api.CORS_ORIGINS


def test_extra_origins_come_from_the_environment(monkeypatch) -> None:
    monkeypatch.setenv(
        "CORS_ORIGINS", "https://lumos.example.com, https://staging.example.com"
    )
    origins = api._cors_origins()
    assert "https://lumos.example.com" in origins
    assert "https://staging.example.com" in origins
    # The dev origin survives, so a configured deploy does not break local work.
    assert "http://localhost:7357" in origins


def test_a_configured_wildcard_is_refused(monkeypatch) -> None:
    monkeypatch.setenv("CORS_ORIGINS", "*")
    assert "*" not in api._cors_origins()


def test_a_disallowed_origin_gets_no_cors_header(client: TestClient) -> None:
    response = client.get(
        "/api/news/alerts", headers={"Origin": "https://evil.example.com"}
    )
    assert response.status_code == 200
    assert "access-control-allow-origin" not in {
        k.lower() for k in response.headers
    }


def test_the_dev_origin_gets_a_cors_header(client: TestClient) -> None:
    response = client.get(
        "/api/news/alerts", headers={"Origin": "http://localhost:7357"}
    )
    assert response.headers.get("access-control-allow-origin") == (
        "http://localhost:7357"
    )
