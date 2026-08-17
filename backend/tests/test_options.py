"""Broad goals must never collapse to one answer.

The bug these cover, in the user's words: *"when i gave my expectations as
working in US, it should give me all the options for doing that and not just
H1b"*. Everything here is deterministic — no API key, no model call — because
the ranking is.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.intake import keyword_resolve
from app.main import app
from app.models import IntakeRequest
from app.options import (
    BUCKETS,
    GOALS,
    SIGNALS,
    build_option_set,
    detect_goal,
    extract_signals,
)
from app.pathways import load_graph

WORK_GOAL = "I want to work in the US"


@pytest.fixture(scope="module")
def graph():
    return load_graph()


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="module")
def option_set(graph):
    return build_option_set(graph, WORK_GOAL)


# ── The regression itself ─────────────────────────────────────────────────────


def test_working_in_the_us_returns_a_landscape_not_h1b(option_set):
    """>= 8 distinct options across >= 3 buckets, and H-1B is only one of them."""
    node_ids = [o.node_id for o in option_set.options]
    assert len(node_ids) == len(set(node_ids)), "each option appears once"
    assert len(node_ids) >= 8, f"only {len(node_ids)} options offered"

    used = {o.bucket for o in option_set.options}
    assert len(used) >= 3, f"options landed in only {used}"
    assert used <= {b[0] for b in BUCKETS}

    assert "temp_worker.h1b" in node_ids
    assert len([n for n in node_ids if n != "temp_worker.h1b"]) >= 7


def test_every_named_route_is_present(option_set):
    """The option set is comprehensive, not a top-N.

    Each of these is a real way to work in the US that a person told "H-1B" is
    never shown.
    """
    node_ids = {o.node_id for o in option_set.options}
    for expected in [
        "temp_worker.h1b",
        "temp_worker.h1b_cap_exempt",
        "temp_worker.e3",
        "temp_worker.h1b1",
        "extraordinary.o1a",
        "extraordinary.o1b",
        "intracompany.l1a",
        "intracompany.l1b",
        "intracompany.e1",
        "intracompany.e2",
        "intracompany.tn",
        "student.cpt",
        "student.opt_postcompletion",
        "student.stem_opt",
        "student.cap_gap",
        "exchange.j1",
        "employment_gc.eb1a",
        "employment_gc.eb1b",
        "employment_gc.eb1c",
        "employment_gc.eb2",
        "employment_gc.eb2_niw",
        "employment_gc.eb3",
        "employment_gc.eb5",
        "dependent.h4_ead",
        "dependent.l2_ead",
        "dependent.e_spouse_ead",
        "humanitarian.asylum",
    ]:
        assert expected in node_ids, f"{expected} missing from the option set"


def test_self_petition_routes_are_surfaced(option_set):
    """The routes people miss when they assume an employer must sponsor them."""
    assert option_set.self_petition_routes, "no self-petition route offered"
    assert "employment_gc.eb2_niw" in option_set.self_petition_routes
    assert "employment_gc.eb1a" in option_set.self_petition_routes

    by_id = {o.node_id: o for o in option_set.options}
    assert by_id["employment_gc.eb2_niw"].allows_self_petition is True
    assert by_id["employment_gc.eb2_niw"].needs_employer_sponsor is False
    assert by_id["temp_worker.h1b"].needs_employer_sponsor is True
    assert by_id["temp_worker.h1b"].allows_self_petition is False

    for node_id in ("employment_gc.eb1a", "employment_gc.eb2_niw", "intracompany.e2"):
        assert node_id in option_set.no_employer_needed


def test_umbrella_nodes_are_never_offered_alongside_their_children(option_set):
    """O-1, L-1 and EB-1 exist as graph positions, not as choices."""
    node_ids = {o.node_id for o in option_set.options}
    for umbrella in ("extraordinary.o1", "intracompany.l1", "employment_gc.eb1"):
        assert umbrella not in node_ids


# ── Metadata contract ─────────────────────────────────────────────────────────


def test_every_option_carries_the_structured_fields(option_set):
    categories = {
        "nonimmigrant work",
        "immigrant",
        "student-work",
        "dependent",
        "investor",
        "humanitarian",
    }
    for option in option_set.options:
        assert option.name
        assert option.category in categories, f"{option.node_id}: {option.category}"
        assert option.summary and option.who_it_fits
        assert option.eligibility_signals
        assert option.typical_timeline and option.cost_ballpark
        assert option.risk_notes and option.next_steps
        assert isinstance(option.needs_employer_sponsor, bool)
        assert isinstance(option.allows_self_petition, bool)
        assert isinstance(option.country_restricted, list)
        assert option.reason, f"{option.node_id} was ranked without saying why"
        assert 0.0 <= option.fit_score <= 1.0
        assert option.source_hint, f"{option.node_id} has no source to verify against"


def test_country_restricted_routes_say_which_country(option_set):
    by_id = {o.node_id: o for o in option_set.options}
    assert by_id["intracompany.tn"].country_restricted == ["Canada", "Mexico"]
    assert by_id["temp_worker.e3"].country_restricted == ["Australia"]
    assert by_id["temp_worker.h1b1"].country_restricted == ["Chile", "Singapore"]
    assert by_id["intracompany.e2"].country_restricted, "E-2 is treaty-dependent"
    # And an unrestricted route must not claim a restriction.
    assert by_id["temp_worker.h1b"].country_restricted == []


def test_disclaimer_travels_with_every_answer(option_set, graph):
    """Real immigration information, so it never ships unqualified."""
    assert "not legal advice" in option_set.disclaimer.lower()
    assert option_set.graph_as_of == graph.as_of

    result = keyword_resolve(IntakeRequest(text=WORK_GOAL), graph)
    assert "not legal advice" in result.disclaimer.lower()


def test_buckets_are_always_all_three_and_partition_the_options(option_set):
    assert [b.id for b in option_set.buckets] == [b[0] for b in BUCKETS]
    from_buckets = [n for b in option_set.buckets for n in b.node_ids]
    assert sorted(from_buckets) == sorted(o.node_id for o in option_set.options)
    for bucket in option_set.buckets:
        assert bucket.label and bucket.description


def test_strategy_notes_cover_the_things_people_miss(option_set):
    ids = {n.id for n in option_set.strategy_notes}
    assert {"parallel_opt_h1b", "no_employer_needed", "country_matters"} <= ids
    for note in option_set.strategy_notes:
        assert note.title and note.body


# ── Ranking behaviour ─────────────────────────────────────────────────────────


def test_options_are_ordered_by_bucket_then_fit(option_set):
    order = {b[0]: i for i, b in enumerate(BUCKETS)}
    keys = [(order[o.bucket], -o.fit_score) for o in option_set.options]
    assert keys == sorted(keys)


def test_saying_you_have_no_employer_demotes_the_sponsored_routes(graph):
    """The exact case that makes the H-1B-only answer harmful."""
    result = build_option_set(graph, "I want to work in the US but I have no job offer")
    by_id = {o.node_id: o for o in result.options}
    assert result.signals_read["us_employer"] is False
    assert by_id["temp_worker.h1b"].bucket == "long_shot"
    assert "do not have" in by_id["temp_worker.h1b"].reason

    # …and the no-employer routes must still be on the table.
    for node_id in ("employment_gc.eb2_niw", "employment_gc.eb1a", "extraordinary.o1a"):
        assert by_id[node_id].bucket != "long_shot", node_id


def test_nationality_opens_and_closes_the_country_gated_routes(graph):
    result = build_option_set(graph, "I am Australian and I want to work in the US")
    by_id = {o.node_id: o for o in result.options}
    assert by_id["temp_worker.e3"].bucket == "strong_fit"
    assert by_id["intracompany.tn"].bucket == "long_shot"
    assert by_id["temp_worker.h1b1"].bucket == "long_shot"
    assert "Australia" in by_id["temp_worker.e3"].reason


def test_a_described_situation_promotes_the_routes_that_fit_it(graph):
    result = build_option_set(
        graph,
        "I am on STEM OPT with a PhD in computer science, several publications "
        "and awards, and my employer wants to sponsor me. I want to keep "
        "working in the US.",
    )
    by_id = {o.node_id: o for o in result.options}
    assert by_id["student.stem_opt"].bucket == "strong_fit"
    assert by_id["temp_worker.h1b"].bucket == "strong_fit"
    assert by_id["employment_gc.eb2_niw"].bucket != "long_shot"
    # Nothing about that description says anything about investing.
    assert by_id["employment_gc.eb5"].bucket == "long_shot"


def test_open_questions_are_real_signal_questions(option_set):
    known = {s.question for s in SIGNALS.values()}
    for option in option_set.options:
        for question in option.open_questions:
            assert question in known
    assert option_set.questions, "an unknown-heavy answer must ask something"
    assert all(q.text in known for q in option_set.questions)


# ── Goal detection ────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("I want to work in the US", "work_in_us"),
        ("i want to work in america", "work_in_us"),
        ("Looking for a job in the United States", "work_in_us"),
        ("I need a work visa", "work_in_us"),
        ("how do I get employment in the U.S.?", "work_in_us"),
        ("I want a green card", "green_card"),
        ("I want to become a permanent resident", "green_card"),
        ("I am on STEM OPT and my I-983 is due", None),
        ("Do I need to report my address change?", None),
    ],
)
def test_detect_goal(text, expected):
    assert detect_goal(text) == expected


def test_signals_are_absent_rather_than_false_when_unsaid():
    """Unknown is not "no" — the whole bucketing depends on the difference."""
    signals = extract_signals("I want to work in the US")
    assert "us_employer" not in signals
    assert "australia" not in signals

    stated = extract_signals("I have no job offer")
    assert stated["us_employer"] is False


# ── Wire shape ────────────────────────────────────────────────────────────────


def test_intake_embeds_the_option_set_for_a_broad_goal(client):
    response = client.post("/api/case/options", json={"text": WORK_GOAL})
    assert response.status_code == 200
    body = response.json()
    assert body["goal"] == "work_in_us"
    assert len(body["options"]) >= 8
    assert len({o["bucket"] for o in body["options"]}) >= 3
    assert body["self_petition_routes"]
    assert body["disclaimer"]


def test_options_endpoint_refuses_to_invent_a_goal(client):
    response = client.post(
        "/api/case/options", json={"text": "My I-94 says my status expires in May"}
    )
    assert response.status_code == 422

    forced = client.post(
        "/api/case/options",
        params={"goal": "work_in_us"},
        json={"text": "My I-94 says my status expires in May"},
    )
    assert forced.status_code == 200
    assert len(forced.json()["options"]) >= 8

    assert (
        client.post(
            "/api/case/options", params={"goal": "emigrate_to_mars"}, json={"text": "x"}
        ).status_code
        == 422
    )


def test_intake_result_carries_the_options_for_a_broad_goal(client):
    from app import main

    main._intake_hits.clear()
    response = client.post("/api/case/intake", json={"text": WORK_GOAL})
    main._intake_hits.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["disclaimer"]
    options = body["options"]
    assert options is not None, "a broad goal must not come back as one node"
    assert len(options["options"]) >= 8
    assert len({o["bucket"] for o in options["options"]}) >= 3


def test_narrow_intake_is_unchanged(graph):
    """The single-node contract still holds for a specific question."""
    result = keyword_resolve(
        IntakeRequest(text="I am on STEM OPT and I want to move to H-1B"), graph
    )
    assert result.current_node_id == "student.stem_opt"
    assert result.goal_node_id == "temp_worker.h1b"
    assert result.options is None


def test_every_goal_produces_a_usable_set(graph):
    for goal in GOALS:
        result = build_option_set(graph, "anything", goal=goal)
        assert result is not None and result.options, goal
        assert result.goal_label
