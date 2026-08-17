"""Case intake — turn a person's description of their situation into a place on
the map, plus where they said they want to get to.

Two resolvers, in this order:

1. **The reasoner** (`claude-opus-5`), constrained by a JSON schema whose node
   fields are an *enum of the real node ids*. The model cannot return a status
   that isn't on the map, and it is told to leave a field null and ask a
   question rather than guess.
2. **Keyword matching**, when no `ANTHROPIC_API_KEY` is configured or the call
   fails. It is deliberately worse, and says so: every result carries
   `source` and `degraded` so the UI can label a guess as a guess.

The frontend has a third path the backend never sees — a fixed questionnaire it
resolves locally — so the product still works with this service switched off.

Nothing here writes anything. Intake *proposes*; the person confirms
(`POST /api/case/confirm`, still spec) and only then does it become their case.
"""

from __future__ import annotations

import json
import logging
import os
import re

from .models import IntakeFact, IntakeQuestion, IntakeRequest, IntakeResult
from .options import DISCLAIMER, build_option_set, detect_goal
from .pathways import PathwayGraph, load_graph

log = logging.getLogger("lumos.intake")

MODEL = os.getenv("INTAKE_MODEL", "claude-opus-5")

#: Intake is a bounded classification over a closed list, not open-ended
#: research — `medium` reads a messy paragraph correctly without paying for
#: deliberation the task doesn't need. Raise it if the reasoning looks shallow.
EFFORT = os.getenv("INTAKE_EFFORT", "medium")

#: Thinking is on by default on Claude Opus 5 and counts against `max_tokens`,
#: so this has to leave room for both the reasoning and the JSON.
MAX_TOKENS = 8000

_UNKNOWN = "unknown"

_SYSTEM = """\
You are the intake reasoner for Lumos, a US immigration pathway tracker.

A person describes their immigration situation in their own words. You place \
them on a fixed map of immigration statuses, and — when they say where they \
want to end up — you place that too.

Rules:
- Choose ONLY from the node ids given below. Never invent one.
- `current_node_id` is where the person is TODAY. If their description does not \
identify one status clearly, return "unknown" and ask a question instead of \
guessing. A confident wrong status is worse than an honest question.
- `goal_node_id` is where they said they want to be. Most people describe a \
situation without naming a destination — return "unknown" rather than \
inferring an ambition they did not express.
- A *direction* is not a destination. "I want to work in the US" names no \
single status, and answering it with one is actively misleading: it is how a \
person comes away believing H-1B is the only route. When the stated aim is \
broad, return "unknown" for `goal_node_id` and list EVERY route that could \
serve it in `alternative_goal_ids` — employer-sponsored and self-petitioned, \
temporary and permanent. The ranked, bucketed option set is built \
deterministically from those ids downstream, so a short list here throws away \
options the person needed to see. Never narrow a broad aim to one answer.
- `facts` are things the person actually stated, in their terms, not \
inferences. Keep labels short.
- `questions` are the things you would need answered to raise your confidence. \
Ask at most three, and only ones that would change the answer. When the goal is \
broad and the routes it could resolve to depend on what the person actually \
does — O-1A vs O-1B, H-1B specialty occupation, EB-1A, NIW, and similar — ask \
what their field, profession, or occupation is. That question narrows a broad \
goal more than visa-mechanical details (program dates, degree classification, \
citizenship) do, so include it rather than crowding it out with those.
- `explanation` is two or three plain sentences addressed to the person, saying \
where you placed them and why. No legal advice, no predictions about whether an \
application will succeed, no invented deadlines or fee amounts.
- Confidence is "high" only when the description names the status or is \
unambiguous about it; "medium" when it is a strong reading of indirect \
evidence; "low" otherwise.

The statuses:
{catalog}
"""


def _schema(node_ids: list[str]) -> dict:
    """The output contract.

    `current_node_id` / `goal_node_id` are enums over the real graph, so an
    invented status is rejected at the API layer rather than caught downstream.
    "unknown" is a member of the enum because the honest answer has to be
    expressible — without it the model is forced to pick a status it doesn't
    believe in.
    """
    node_enum = [*node_ids, _UNKNOWN]
    confidence = {"type": "string", "enum": ["high", "medium", "low"]}
    return {
        "type": "object",
        "properties": {
            "current_node_id": {"type": "string", "enum": node_enum},
            "current_confidence": confidence,
            "goal_node_id": {"type": "string", "enum": node_enum},
            "goal_confidence": confidence,
            "alternative_goal_ids": {
                "type": "array",
                "items": {"type": "string", "enum": node_ids},
            },
            "facts": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "label": {"type": "string"},
                        "value": {"type": "string"},
                    },
                    "required": ["label", "value"],
                    "additionalProperties": False,
                },
            },
            "questions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "text": {"type": "string"},
                        "type": {
                            "type": "string",
                            "enum": ["boolean", "text", "choice"],
                        },
                        "options": {"type": "array", "items": {"type": "string"}},
                    },
                    "required": ["id", "text", "type", "options"],
                    "additionalProperties": False,
                },
            },
            "explanation": {"type": "string"},
        },
        "required": [
            "current_node_id",
            "current_confidence",
            "goal_node_id",
            "goal_confidence",
            "alternative_goal_ids",
            "facts",
            "questions",
            "explanation",
        ],
        "additionalProperties": False,
    }


# ── Keyword fallback ──────────────────────────────────────────────────────────

#: Ordered most-specific first — "STEM OPT" must win over "OPT", which must win
#: over "F-1". Each entry is (pattern, node id).
_KEYWORDS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bstem[\s-]?opt\b|\b24[\s-]month extension\b", re.I), "student.stem_opt"),
    (re.compile(r"\bcap[\s-]?gap\b", re.I), "student.cap_gap"),
    (re.compile(r"\bpre[\s-]?completion opt\b", re.I), "student.opt_precompletion"),
    (re.compile(r"\bopt\b|\bpost[\s-]?completion\b|\bi[\s-]?765\b", re.I), "student.opt_postcompletion"),
    (re.compile(r"\bcpt\b|\bcurricular practical\b", re.I), "student.cpt"),
    (re.compile(r"\bf[\s-]?1\b|\bstudent visa\b|\bi[\s-]?20\b|\bsevis\b", re.I), "student.f1"),
    (re.compile(r"\bj[\s-]?1\b|\bexchange visitor\b|\bds[\s-]?2019\b", re.I), "exchange.j1"),
    (re.compile(r"\bh[\s-]?1[\s-]?b\b|\bspecialty occupation\b|\blottery\b", re.I), "temp_worker.h1b"),
    (re.compile(r"\bh[\s-]?2a\b|\bagricultural worker\b", re.I), "temp_worker.h2a"),
    (re.compile(r"\bh[\s-]?2b\b", re.I), "temp_worker.h2b"),
    (re.compile(r"\bl[\s-]?1\b|\bintracompany\b|\btransferr?ed by my (company|employer)\b", re.I), "intracompany.l1"),
    (re.compile(r"\be[\s-]?1\b|\btreaty trader\b", re.I), "intracompany.e1"),
    (re.compile(r"\be[\s-]?2\b|\btreaty investor\b", re.I), "intracompany.e2"),
    (re.compile(r"\btn\b|\busmca\b|\bnafta\b", re.I), "intracompany.tn"),
    (re.compile(r"\bo[\s-]?1\b|\bextraordinary ability\b", re.I), "extraordinary.o1"),
    (re.compile(r"\bp[\s-]?1\b|\bathlete\b", re.I), "extraordinary.p1"),
    (re.compile(r"\br[\s-]?1\b|\breligious worker\b", re.I), "temp_worker.r1"),
    (re.compile(r"\bk[\s-]?1\b|\bfianc", re.I), "family_temp.k1"),
    (re.compile(r"\beb[\s-]?1\b|\bpriority worker\b", re.I), "employment_gc.eb1"),
    (re.compile(r"\bniw\b|\bnational interest waiver\b", re.I), "employment_gc.eb2_niw"),
    (re.compile(r"\beb[\s-]?2\b|\bperm\b|\blabor certification\b", re.I), "employment_gc.eb2"),
    (re.compile(r"\beb[\s-]?3\b", re.I), "employment_gc.eb3"),
    (re.compile(r"\beb[\s-]?4\b", re.I), "employment_gc.eb4"),
    (re.compile(r"\beb[\s-]?5\b|\binvestor visa\b", re.I), "employment_gc.eb5"),
    (re.compile(r"\bmarri(ed|age) to a? ?(us|american) citizen\b|\bmarriage[\s-]based\b|\bi[\s-]?485\b", re.I), "family_gc.marriage_aos"),
    (re.compile(r"\bimmediate relative\b|\bmy (spouse|husband|wife) is a (us|american) citizen\b", re.I), "family_gc.immediate_relative"),
    (re.compile(r"\bf2a\b", re.I), "family_gc.f2a"),
    (re.compile(r"\bf2b\b", re.I), "family_gc.f2b"),
    (re.compile(r"\bf3\b", re.I), "family_gc.f3"),
    (re.compile(r"\bf4\b|\bsibling\b", re.I), "family_gc.f4"),
    (re.compile(r"\bdiversity visa\b|\bdv lottery\b|\bgreen card lottery\b", re.I), "diversity.dv"),
    (re.compile(r"\basylum\b|\basylee\b|\bi[\s-]?589\b", re.I), "humanitarian.asylum"),
    (re.compile(r"\brefugee\b", re.I), "humanitarian.refugee"),
    (re.compile(r"\bu[\s-]?visa\b|\bcrime victim\b", re.I), "humanitarian.u_visa"),
    (re.compile(r"\bt[\s-]?visa\b|\btrafficking\b", re.I), "humanitarian.t_visa"),
    (re.compile(r"\bvawa\b", re.I), "humanitarian.vawa"),
    (re.compile(r"\btps\b|\btemporary protected status\b", re.I), "humanitarian.tps"),
    (re.compile(r"\bhumanitarian parole\b|\bparole\b", re.I), "humanitarian.parole"),
    (re.compile(r"\bsij\b|\bspecial immigrant juvenile\b", re.I), "special_immigrant.sij"),
    (re.compile(r"\bconditional (green card|permanent resident)\b|\bi[\s-]?751\b|\b2[\s-]year green card\b", re.I), "post_lpr.conditional_gc"),
    (re.compile(r"\bnaturaliz|\bcitizenship\b|\bn[\s-]?400\b|\bbecome a citizen\b", re.I), "post_lpr.naturalization"),
    (re.compile(r"\bgreen card\b|\bpermanent resident\b|\blpr\b", re.I), "post_lpr.lpr"),
]

#: Everything after one of these reads as aspiration rather than situation, so
#: the keyword resolver scores it for the goal instead of the current status.
_GOAL_SPLIT = re.compile(
    r"\b(i want to|i'd like to|i would like to|hoping to|my goal is|aiming for|"
    r"trying to get|eventually|next step|so that i can|in order to)\b",
    re.I,
)


def _match(text: str) -> str | None:
    for pattern, node_id in _KEYWORDS:
        if pattern.search(text):
            return node_id
    return None


def keyword_resolve(request: IntakeRequest, graph: PathwayGraph) -> IntakeResult:
    """A deterministic, obviously-limited reading.

    It only ever matches a status people *name*. Somebody who writes "I finished
    my masters in May and my employer is sponsoring me" says nothing this can
    match, and getting nothing back is the correct outcome — the UI then offers
    the questionnaire.
    """
    text = request.text
    # The split pattern captures, so this is [situation, marker, aspiration].
    parts = _GOAL_SPLIT.split(text, maxsplit=1)
    situation = parts[0]
    aspiration = parts[-1] if len(parts) > 1 else ""
    if request.goal:
        aspiration = f"{aspiration} {request.goal}"

    current = _match(situation) or _match(text)
    goal = _match(aspiration) if aspiration.strip() else None
    if goal == current:
        goal = None

    # A *direction* ("I want to work in the US") is not a missing goal — it is a
    # goal that no single node answers. Detecting it here is what stops the
    # fallback asking "where would you like to end up?" at somebody who just
    # said, and then answering with one status.
    broad_goal = detect_goal(text, request.goal)

    questions: list[IntakeQuestion] = []
    if current is None:
        questions.append(
            IntakeQuestion(
                id="q_status_name",
                text="Which status are you on right now — for example F-1, OPT, "
                "H-1B, or a green card?",
                type="text",
            )
        )
    if goal is None and broad_goal is None:
        questions.append(
            IntakeQuestion(
                id="q_goal_name",
                text="Where would you like to end up?",
                type="text",
            )
        )
    # A broad goal ("work in the US") resolves to a list that spans routes
    # gated by what the person does — O-1A vs O-1B, H-1B specialty occupation,
    # EB-1A, NIW. That narrows the list more than any visa-mechanical detail,
    # so it belongs here even though no keyword pattern can answer it.
    if goal is None and broad_goal is not None:
        questions.append(
            IntakeQuestion(
                id="q_field",
                text="What is your field, profession, or occupation?",
                type="text",
            )
        )

    matched = graph.node(current) if current else None
    explanation = (
        f"Matched the words in your description to {matched.name}."
        if matched
        else "Nothing in your description named a status this could match."
    )

    result = IntakeResult(
        current_node_id=current,
        current_confidence="low",
        goal_node_id=goal,
        goal_confidence="low",
        facts=[IntakeFact(label="In your words", value=" ".join(text.split())[:280])],
        questions=questions,
        explanation=explanation
        + " This is a plain word match, not a reading of your situation — "
        "check it against the map before relying on it.",
        source="keywords",
    )
    return attach_options(result, request, graph, goal=broad_goal)


def attach_options(
    result: IntakeResult,
    request: IntakeRequest,
    graph: PathwayGraph,
    goal: str | None = None,
) -> IntakeResult:
    """Hang the full ranked option set off a result, when the goal was broad.

    Both resolvers go through here, so the reasoner and the keyword fallback
    return the same shape. Nothing about the single-node fields changes — the
    option set is additive, and absent when the person named a specific
    destination.
    """
    result.disclaimer = result.disclaimer or DISCLAIMER
    if result.options is None:
        result.options = build_option_set(
            graph, request.text, request.goal, goal=goal
        )
    if result.options is not None and not result.explanation.startswith("There is"):
        goal_label = result.options.goal_label.lower()
        result.explanation = (
            f"There is more than one route to this. {result.explanation} "
            f"Below are {len(result.options.options)} routes that can lead to "
            f"{goal_label}, ranked by how well they fit what you have told us "
            "— including several that need no employer sponsor."
        ).strip()
    return result


# ── Reasoner ──────────────────────────────────────────────────────────────────


class IntakeResolver:
    """Holds the Anthropic client and the graph the model is constrained to."""

    def __init__(self) -> None:
        self.graph = load_graph()
        self._client = None
        self._client_error: str | None = None

        if not os.getenv("ANTHROPIC_API_KEY"):
            self._client_error = "ANTHROPIC_API_KEY is not set"
            return
        try:
            from anthropic import AsyncAnthropic

            self._client = AsyncAnthropic()
        except Exception as e:  # noqa: BLE001 — missing package or bad config
            self._client_error = f"{type(e).__name__}: {e}"
            log.warning("intake reasoner unavailable (%s)", self._client_error)

    @property
    def llm_available(self) -> bool:
        return self._client is not None

    async def resolve(self, request: IntakeRequest) -> IntakeResult:
        if self._client is None:
            result = keyword_resolve(request, self.graph)
            result.degraded = True
            return result

        try:
            result = await self._resolve_with_model(request)
            return attach_options(result, request, self.graph)
        except Exception:  # noqa: BLE001
            # A person mid-intake gets the weaker answer rather than a 500.
            log.exception("intake reasoner failed; falling back to keywords")
            result = keyword_resolve(request, self.graph)
            result.degraded = True
            return result

    async def _resolve_with_model(self, request: IntakeRequest) -> IntakeResult:
        assert self._client is not None

        prompt = request.text
        if request.goal:
            prompt += f"\n\nWhere I want to end up: {request.goal}"

        response = await self._client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=[
                {
                    "type": "text",
                    "text": _SYSTEM.format(catalog=self.graph.catalog()),
                    # The system prompt is the same on every request and is by
                    # far the largest part of it, so it caches cleanly — the
                    # person's text is the only thing that varies, and it comes
                    # after this breakpoint.
                    "cache_control": {"type": "ephemeral"},
                }
            ],
            output_config={
                "effort": EFFORT,
                "format": {
                    "type": "json_schema",
                    "schema": _schema(self.graph.ids),
                },
            },
            messages=[{"role": "user", "content": prompt}],
        )

        if response.stop_reason == "refusal":
            # The classifiers declined. There is a deterministic path right
            # here, so use it rather than surfacing a dead end.
            log.warning("intake refused by safety classifiers; using keywords")
            result = keyword_resolve(request, self.graph)
            result.degraded = True
            return result

        text = next((b.text for b in response.content if b.type == "text"), "")
        data = json.loads(text)
        return self._to_result(data)

    def _to_result(self, data: dict) -> IntakeResult:
        def node(key: str) -> str | None:
            value = data.get(key)
            if not value or value == _UNKNOWN or not self.graph.has(value):
                return None
            return value

        current = node("current_node_id")
        goal = node("goal_node_id")

        return IntakeResult(
            current_node_id=current,
            current_confidence=(
                data.get("current_confidence", "low") if current else "low"
            ),
            goal_node_id=goal,
            goal_confidence=data.get("goal_confidence", "low") if goal else "low",
            # Not truncated to a handful any more. A broad goal legitimately
            # has a dozen routes, and cutting the list here was half of why
            # "I want to work in the US" came back as H-1B and nothing else.
            alternative_goal_ids=[
                n
                for n in data.get("alternative_goal_ids") or []
                if self.graph.has(n) and n != goal
            ],
            facts=[
                IntakeFact(label=str(f.get("label", "")), value=str(f.get("value", "")))
                for f in (data.get("facts") or [])
                if f.get("label") and f.get("value")
            ][:8],
            questions=[
                IntakeQuestion(
                    id=str(q.get("id") or f"q_{i}"),
                    text=str(q.get("text", "")),
                    type=str(q.get("type") or "text"),
                    options=[str(o) for o in (q.get("options") or [])],
                )
                for i, q in enumerate(data.get("questions") or [])
                if q.get("text")
            ][:3],
            explanation=str(data.get("explanation", "")),
            source="llm",
        )
