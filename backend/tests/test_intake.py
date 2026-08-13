"""Case intake — the resolvers that do not need an API key.

The reasoning path is not exercised here (it needs a live model); what is
covered is everything that decides whether that path can be trusted: the node
ids the fallback can emit, the schema the model is constrained by, and the
endpoints' behaviour when no key is configured.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.intake import _KEYWORDS, _UNKNOWN, _schema, keyword_resolve
from app.main import app
from app.models import IntakeRequest
from app.pathways import load_graph


@pytest.fixture(scope="module")
def graph():
    return load_graph()


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


def test_graph_loads_with_every_node_named(graph):
    assert len(graph.nodes) >= 40
    for node in graph.nodes:
        assert node.id and node.name
        assert graph.has(node.id)


def test_keyword_table_only_points_at_real_nodes(graph):
    """A typo here would send someone to a status that does not exist."""
    for pattern, node_id in _KEYWORDS:
        assert graph.has(node_id), f"{pattern.pattern} → unknown node {node_id}"


def test_schema_constrains_both_node_fields_to_the_graph(graph):
    schema = _schema(graph.ids)
    for field in ("current_node_id", "goal_node_id"):
        enum = schema["properties"][field]["enum"]
        assert set(graph.ids).issubset(enum)
        assert _UNKNOWN in enum, "the model must be able to say it does not know"
    assert schema["additionalProperties"] is False
    assert "explanation" in schema["required"]


def test_catalog_lists_every_node_once(graph):
    catalog = graph.catalog()
    for node in graph.nodes:
        assert catalog.count(f"- {node.id} —") == 1


@pytest.mark.parametrize(
    ("text", "current", "goal"),
    [
        ("I am on STEM OPT and I want to move to H-1B", "student.stem_opt", "temp_worker.h1b"),
        ("I'm on an H-1B, hoping to get a green card through my employer", "temp_worker.h1b", None),
        ("married to a US citizen, my goal is citizenship", "family_gc.marriage_aos", "post_lpr.naturalization"),
        ("I have TPS right now", "humanitarian.tps", None),
    ],
)
def test_keyword_resolver_reads_named_statuses(graph, text, current, goal):
    result = keyword_resolve(IntakeRequest(text=text), graph)
    assert result.current_node_id == current
    if goal is not None:
        assert result.goal_node_id == goal
    assert result.source == "keywords"
    assert result.current_confidence == "low", "a word match is never confident"


def test_keyword_resolver_asks_rather_than_guesses(graph):
    """A description that names no status must resolve to nothing.

    "I finished my masters and my employer is sponsoring me" is a perfectly
    clear situation to a human and matches no keyword — returning a plausible
    status here would be worse than returning none.
    """
    result = keyword_resolve(
        IntakeRequest(text="I finished my masters in May and my employer is sponsoring me"),
        graph,
    )
    assert result.current_node_id is None
    assert result.goal_node_id is None
    assert len(result.questions) == 2


def test_status_endpoint_answers_honestly_either_way(client):
    """The client decides which intake path to lead with from this response.

    Asserted as an invariant rather than a fixed value so the suite passes both
    with and without a key in the environment: a model is named exactly when
    one is available.
    """
    body = client.get("/api/case/intake/status").json()
    assert body["node_count"] >= 40
    assert body["graph_as_of"]
    assert (body["model"] is not None) == body["llm_available"]


def test_intake_falls_back_instead_of_failing(client):
    """With no key configured, intake still answers — and says it degraded."""
    from app.main import intake_resolver

    response = client.post(
        "/api/case/intake",
        json={"text": "I am on STEM OPT and I want to move to H-1B"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["current_node_id"] == "student.stem_opt"
    if not intake_resolver.llm_available:
        assert body["source"] == "keywords"
        assert body["degraded"] is True, "a fallback answer must be labelled"


def test_intake_rejects_empty_text(client):
    assert client.post("/api/case/intake", json={"text": ""}).status_code == 422


def test_intake_is_rate_limited(client):
    from app import main

    main._intake_hits.clear()
    payload = {"text": "I am on OPT"}
    for _ in range(main.INTAKE_LIMIT):
        assert client.post("/api/case/intake", json=payload).status_code == 200
    assert client.post("/api/case/intake", json=payload).status_code == 429
    main._intake_hits.clear()
