"""Broad-goal option sets — "I want to work in the US" → every plausible route.

Why this module exists
----------------------
Intake resolves a person to *one* current node and *one* goal node
(`app/intake.py`). That is the right shape for placing somebody on the map, and
the wrong shape for answering a broad ambition. Somebody who says "I want to
work in the US" has not named a destination; they have named a *direction*, and
collapsing a direction to the single closest node is how a person ends up
believing H-1B is the only door.

So a broad goal is answered here instead, by a deterministic ranking over every
node in `generic_pathways.json` that carries a `work_option` block. It returns
all of them, bucketed:

    strong_fit          — nothing we know about you argues against it
    possible_with_changes — plausible, but it turns on facts we don't have
    long_shot           — needs a specific circumstance you have not described

Every option carries a `reason` saying *why* it landed in its bucket, and the
set carries `no_employer_needed` up front, because the routes people miss when
they assume H-1B is the only option (O-1A, EB-1A, EB-2 NIW, E-2, EB-5) are
exactly the ones that need no sponsor.

Deterministic on purpose: no model call, no key required, same answer every
time. The reasoner in `intake.py` reads the person's situation; this ranks the
closed set of routes against what it read.

Accuracy note: everything factual here lives in the JSON, phrased generically
and cautiously, and every response carries `DISCLAIMER`. This module only
*orders* those descriptions — it does not assert any rule of its own.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .models import (
    IntakeQuestion,
    OptionBucket,
    PathwayOption,
    PathwayOptionSet,
    StrategyNote,
)
from .pathways import PathwayGraph

#: Shown with every option set. Immigration rules, fees and processing times
#: change constantly and outcomes are case-specific.
DISCLAIMER = (
    "Informational only, not legal advice. US immigration rules, fees, caps and "
    "processing times change often and outcomes are case-specific — verify "
    "anything here against the linked official source and, for a real filing, "
    "with a licensed immigration attorney."
)

# ── Goals ─────────────────────────────────────────────────────────────────────

#: A broad goal is a direction, not a destination. These are the directions this
#: module can answer; anything else falls through to the ordinary single-node
#: intake result.
GOALS: dict[str, dict[str, str]] = {
    "work_in_us": {
        "label": "Work in the United States",
        "description": (
            "Every route that can lead to lawful employment in the US, ranked "
            "against what you have told us so far. Nobody qualifies for all of "
            "these — the point is that the list is longer than most people "
            "expect, and several routes need no employer at all."
        ),
    },
    "green_card": {
        "label": "Permanent residence (green card) through work",
        "description": (
            "Employment-based and self-petitioned routes to permanent residence. "
            "These run in parallel with a temporary work status rather than "
            "replacing it."
        ),
    },
}

#: "the US" written every way people write it, without requiring a trailing
#: word boundary — "in the U.S.?" ends on punctuation, and `\b` fails there.
_US = r"(?:the\s+)?(?:u\.?s\.?a?\.?|america|united\s+states|states)(?!\w)"
_WORK = r"(?:work(?:ing)?|job|employ(?:ed|ment)|career|hired?|earn\s+a\s+living)"

_WORK_GOAL = re.compile(
    rf"\b{_WORK}\b[^.]{{0,60}}?\b(?:in|to|for|inside)\s+{_US}"
    rf"|\b{_US}[^.]{{0,30}}?\b(?:work\s+permit|work\s+visa|work\s+authoriz)"
    r"|\bwork\s+visa\b|\bwork\s+permit\b|\bwork\s+authoriz\w*"
    rf"|\b(?:move|relocat\w*|come|migrat\w*|immigrat\w*)\b[^.]{{0,40}}\b{_US}[^.]{{0,40}}\b{_WORK}\b",
    re.I,
)

_GC_GOAL = re.compile(
    r"\bgreen card\b|\bpermanent resident\w*\b|\blpr\b|\bimmigrate permanently\b",
    re.I,
)


def detect_goal(text: str, goal: str | None = None) -> str | None:
    """Which broad direction, if any, this person described.

    Deliberately conservative: a person who names a specific status ("I want
    H-1B") is not asking for the whole landscape, and intake's single-node
    answer serves them better.
    """
    blob = f"{text} {goal or ''}"
    if _WORK_GOAL.search(blob):
        return "work_in_us"
    if _GC_GOAL.search(blob):
        return "green_card"
    return None


# ── Signals ───────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Signal:
    """One thing about a person that moves options between buckets.

    `unknown_cost` is how much not knowing hurts; `false_cost` is how much a
    known "no" hurts. They differ a lot: not knowing whether somebody has a job
    offer barely matters (most people can get one), while not knowing whether
    they are Australian matters enormously for E-3, because most people are not.
    """

    id: str
    label: str
    #: Phrased as a question, for the UI to ask.
    question: str
    unknown_cost: float
    false_cost: float


def _sig(id_: str, label: str, question: str, unknown: float, false: float) -> Signal:
    return Signal(id_, label, question, unknown, false)


SIGNALS: dict[str, Signal] = {
    s.id: s
    for s in [
        _sig("us_employer", "a US employer willing to sponsor you",
             "Do you have a US job offer, or an employer willing to sponsor?", 0.10, 0.45),
        _sig("cap_exempt_employer", "a cap-exempt employer (university, affiliated nonprofit, nonprofit or government research)",
             "Could you take a role at a university, affiliated nonprofit, or nonprofit/government research organisation?", 0.25, 0.50),
        _sig("bachelors_degree", "a bachelor's degree or equivalent",
             "Do you hold a bachelor's degree or an evaluated equivalent?", 0.08, 0.50),
        _sig("advanced_degree", "an advanced degree or exceptional ability",
             "Do you hold a master's, doctorate, or comparable exceptional ability?", 0.15, 0.35),
        _sig("stem_degree", "a degree on the DHS STEM designated list",
             "Is your degree on the DHS STEM designated degree list?", 0.15, 0.45),
        _sig("student_f1", "F-1 student status at a US school",
             "Are you studying, or planning to study, at a US school in F-1 status?", 0.25, 0.60),
        _sig("on_opt", "a current period of post-completion OPT",
             "Are you currently on post-completion OPT?", 0.30, 0.60),
        _sig("research_background", "a research or academic track record",
             "Do you work in research or academia?", 0.25, 0.45),
        _sig("extraordinary_evidence", "a documented record of acclaim (awards, publications, press, judging, patents)",
             "Do you have awards, publications, citations, press coverage, patents or judging experience?", 0.30, 0.60),
        _sig("strong_record", "a track record substantial enough to argue national importance",
             "Can you evidence the impact and adoption of your work?", 0.25, 0.55),
        _sig("arts_or_media", "work in the arts, film or television",
             "Do you work in the arts, film or television?", 0.30, 0.60),
        _sig("multinational_employer", "an employer with related entities in the US and abroad",
             "Does your employer have a US parent, branch, subsidiary or affiliate?", 0.30, 0.60),
        _sig("year_abroad_with_employer", "the qualifying period of employment abroad with that employer (commonly cited as one continuous year in the last three)",
             "Have you worked for that employer outside the US for at least a continuous year in the last three?", 0.30, 0.60),
        _sig("manager_role", "an executive or managerial role",
             "Is your role executive or managerial in substance?", 0.25, 0.45),
        _sig("investment_capital", "capital you can genuinely put at risk in a US business",
             "Do you have capital you could invest in, and actively direct, a US business?", 0.35, 0.70),
        _sig("large_investment_capital", "investment capital at the EB-5 statutory level",
             "Could you invest at the EB-5 statutory minimum (verify the current amount)?", 0.45, 0.80),
        _sig("trade_or_business", "substantial ongoing trade between the US and your country",
             "Does your business carry on substantial trade with the US?", 0.35, 0.70),
        _sig("business_owner", "ownership of a business",
             "Do you own or co-found a business?", 0.20, 0.30),
        _sig("treaty_country", "nationality of a country with the relevant US trade treaty",
             "Which country's nationality do you hold? E-1/E-2 depend on a treaty list that changes.", 0.25, 0.70),
        _sig("australia", "Australian nationality", "Are you an Australian citizen?", 0.40, 0.90),
        _sig("chile_singapore", "Chilean or Singaporean nationality",
             "Are you a citizen of Chile or Singapore?", 0.40, 0.90),
        _sig("canada_mexico", "Canadian or Mexican citizenship",
             "Are you a Canadian or Mexican citizen?", 0.40, 0.90),
        _sig("exchange_program", "a designated US exchange programme sponsor",
             "Is a US institution willing to sponsor you on an exchange programme?", 0.30, 0.60),
        _sig("spouse_principal_h1b", "a spouse on H-1B who has reached the qualifying milestone",
             "Is your spouse on H-1B with an approved I-140?", 0.40, 0.80),
        _sig("spouse_principal_l1", "a spouse on L-1", "Is your spouse on L-1?", 0.40, 0.80),
        _sig("spouse_principal_e", "a spouse on E-1, E-2 or E-3",
             "Is your spouse on E-1, E-2 or E-3?", 0.40, 0.80),
        _sig("asylum_claim", "a genuine protection claim",
             "Do you fear persecution in your home country on a protected ground?", 0.45, 0.90),
        _sig("in_us", "being physically in the US already",
             "Are you currently in the United States?", 0.05, 0.15),
    ]
}

_BOOST = 0.05

#: Nationality → the country-restricted signals it settles. Detection is only
#: used to *open* nationality-gated routes and to close them when a different
#: nationality is stated; it never guesses at the E-1/E-2 treaty list, which
#: changes and is the State Department's to publish.
_NATIONALITIES: dict[str, str] = {
    "australia": "australia", "australian": "australia",
    "chile": "chile_singapore", "chilean": "chile_singapore",
    "singapore": "chile_singapore", "singaporean": "chile_singapore",
    "canada": "canada_mexico", "canadian": "canada_mexico",
    "mexico": "canada_mexico", "mexican": "canada_mexico",
}

#: Other nationalities we can recognise well enough to say "not Australian" —
#: nothing more is inferred from them.
_OTHER_NATIONALITIES = re.compile(
    r"\b(india|indian|china|chinese|pakistan|pakistani|bangladesh|bangladeshi|nepal|nepali|"
    r"nigeria|nigerian|brazil|brazilian|colombia|colombian|argentin\w+|peru|peruvian|"
    r"uk|british|england|english citizen|ireland|irish|germany|german|france|french|italy|italian|"
    r"spain|spanish|netherlands|dutch|sweden|swedish|poland|polish|ukraine|ukrainian|russia|russian|"
    r"turkey|turkish|egypt|egyptian|israel|israeli|iran|iranian|japan|japanese|korea|korean|"
    r"taiwan|taiwanese|vietnam|vietnamese|indonesia|indonesian|thailand|thai|philippines|filipino|"
    r"south africa\w*|kenya|kenyan|ghana|ghanaian|ethiopia|ethiopian|new zealand)\b",
    re.I,
)

_TRUE_PATTERNS: dict[str, re.Pattern[str]] = {
    "us_employer": re.compile(
        r"\bjob offer\b|\bmy employer\b|\bemployer (is |will |wants to )?sponsor|"
        r"\bi work (at|for)\b|\bi've been hired\b|\bi was hired\b|\bmy company\b|"
        r"\bmy manager\b|\boffer letter\b|\bsponsoring me\b", re.I),
    "cap_exempt_employer": re.compile(
        r"\buniversit\w+|\bcollege\b|\bnon-?profit\b|\bresearch (institut\w+|lab|center|centre|organi\w+)\b|"
        r"\bpostdoc\w*|\bacademia\b|\bacademic\b|\bteaching hospital\b|\bnational lab\w*", re.I),
    "bachelors_degree": re.compile(
        r"\bbachelor\w*|\bundergraduate degree\b|\bmaster'?s?\b|\bms\b|\bmsc\b|\bmba\b|\bph\.?d\b|"
        r"\bdoctorate\b|\bmy degree\b|\bgraduat(ed|ing)\b", re.I),
    "advanced_degree": re.compile(
        r"\bmaster'?s?\b|\bms\b|\bmsc\b|\bmba\b|\bph\.?d\b|\bdoctorate\b|\badvanced degree\b|"
        r"\bexceptional ability\b", re.I),
    "stem_degree": re.compile(
        r"\bstem\b|\bcomputer science\b|\bsoftware\b|\bengineer\w*|\bdata scien\w+|\bmachine learning\b|"
        r"\bphysics\b|\bchemistry\b|\bbiolog\w+|\bmathematic\w+|\bstatistic\w+|\bbioinformatic\w+", re.I),
    "student_f1": re.compile(
        r"\bf[\s-]?1\b|\bi[\s-]?20\b|\bsevis\b|\bstudent visa\b|\bi'?m a student\b|\bmy dso\b|"
        r"\bopt\b|\bcpt\b|\bmy (masters|master'?s|phd|degree) (at|in|from) \w+", re.I),
    "on_opt": re.compile(r"\bopt\b|\bpost[\s-]?completion\b|\bstem opt\b|\bead\b", re.I),
    "research_background": re.compile(
        r"\bresearch\w*|\bph\.?d\b|\bpostdoc\w*|\bpublicat\w+|\bpublished\b|\bprofessor\b|\bfaculty\b|"
        r"\blab\b|\bscientist\b", re.I),
    "extraordinary_evidence": re.compile(
        r"\baward\w*|\bprize\b|\bcitation\w*|\bcited\b|\bpatent\w*|\bpress\b|\bmedia coverage\b|"
        r"\bkeynote\b|\bpeer review\w*|\bjudg(e|ed|ing)\b|\binternational(ly)? recogni\w+|"
        r"\bnational team\b|\bolympic\w*|\beditorial board\b|\bh-?index\b", re.I),
    "arts_or_media": re.compile(
        r"\bartist\b|\bmusician\b|\bdancer\b|\bactor\b|\bactress\b|\bdesigner\b|\bfilm\b|\btelevision\b|"
        r"\bcinemat\w+|\bchoreograph\w+|\bchef\b|\bphotographer\b|\bfashion\b", re.I),
    "multinational_employer": re.compile(
        r"\bmultinational\b|\bus (office|branch|subsidiary|affiliate|entity|arm)\b|\bglobal (company|firm)\b|"
        r"\bintracompany\b|\btransferr?(ed|ing)\b|\bour (parent|subsidiary)\b|\bopen(ing)? a us (office|entity)\b", re.I),
    "year_abroad_with_employer": re.compile(
        r"\b(one|two|three|four|five|\d+)\s*(\+)?\s*years?\b[^.]{0,40}\b(with|at|for)\b[^.]{0,30}"
        r"\b(company|employer|firm|organi\w+)\b", re.I),
    "manager_role": re.compile(
        r"\bmanager\b|\bmanaging\b|\bdirector\b|\bexecutive\b|\bvp\b|\bvice president\b|\bhead of\b|"
        r"\bfounder\b|\bceo\b|\bcto\b|\bcoo\b|\blead a team\b", re.I),
    "investment_capital": re.compile(
        r"\binvest\w*|\bcapital\b|\bstart a business\b|\bopen a (business|restaurant|shop|franchise)\b|"
        r"\bbuy a business\b|\bfranchise\b|\bsavings to put\b", re.I),
    "large_investment_capital": re.compile(r"\beb[\s-]?5\b|\bmillion\b|\b800,?000\b|\b1,?050,?000\b", re.I),
    "trade_or_business": re.compile(r"\btrade\b|\bimport\w*|\bexport\w*|\bmy business\b|\bmy company\b", re.I),
    "business_owner": re.compile(r"\bfounder\b|\bco-?found\w+|\bi own\b|\bmy startup\b|\bmy business\b", re.I),
    "treaty_country": re.compile(r"\btreaty (country|trader|investor)\b", re.I),
    "exchange_program": re.compile(r"\bj[\s-]?1\b|\bds[\s-]?2019\b|\bexchange (visitor|program\w*)\b|\bfulbright\b", re.I),
    "spouse_principal_h1b": re.compile(
        r"\bh[\s-]?4\b|\b(spouse|husband|wife|partner)\b[^.]{0,40}\bh[\s-]?1[\s-]?b\b", re.I),
    "spouse_principal_l1": re.compile(
        r"\bl[\s-]?2\b|\b(spouse|husband|wife|partner)\b[^.]{0,40}\bl[\s-]?1\b", re.I),
    "spouse_principal_e": re.compile(
        r"\b(spouse|husband|wife|partner)\b[^.]{0,40}\be[\s-]?[123]\b", re.I),
    "asylum_claim": re.compile(r"\basylum\b|\basylee\b|\bpersecut\w+|\brefugee\b|\bafraid to (go|return)\b", re.I),
    "in_us": re.compile(
        r"\bi (am|'m) (currently )?(in|living in|here in) the (us|u\.s\.|usa|united states)\b|"
        r"\bhere in the (us|states)\b|\bcurrently in the (us|united states)\b|"
        r"\bf[\s-]?1\b|\bopt\b|\bh[\s-]?1[\s-]?b\b", re.I),
}

#: A stated negative beats an inferred positive.
_FALSE_PATTERNS: dict[str, re.Pattern[str]] = {
    "us_employer": re.compile(
        r"\bno (us )?(job|job offer|employer|sponsor\w*)\b|\bdon'?t have a job\b|"
        r"\bwithout an employer\b|\bno one will sponsor\b|\bno sponsorship\b", re.I),
    "student_f1": re.compile(r"\bnot a student\b|\bdon'?t want to study\b|\bno interest in studying\b", re.I),
    "in_us": re.compile(
        r"\bi (am|'m) (currently )?(outside|not in) the (us|united states)\b|\bfrom abroad\b|"
        r"\bstill in my home country\b|\bnever been to the (us|united states)\b", re.I),
    "investment_capital": re.compile(r"\bno (money|capital|savings)\b|\bcan'?t invest\b|\bnothing to invest\b", re.I),
}


def extract_signals(text: str) -> dict[str, bool]:
    """What the description actually says. Absent key == unknown, not false.

    Unknown is the common case and the honest one — the option set says so
    rather than assuming a "no", and the unknowns become the questions the UI
    asks next.
    """
    found: dict[str, bool] = {}

    for name, pattern in _TRUE_PATTERNS.items():
        if pattern.search(text):
            found[name] = True
    for name, pattern in _FALSE_PATTERNS.items():
        if pattern.search(text):
            found[name] = False

    # Derived: being on OPT means being an F-1 student, and a research or
    # acclaim record is what "strong record" is asking about.
    if found.get("on_opt"):
        found.setdefault("student_f1", True)
    if found.get("extraordinary_evidence") or found.get("research_background"):
        found["strong_record"] = True

    # Nationality. Only the country-gated signals are settled from it; the E-1 /
    # E-2 treaty list is not inferred, because it changes and is not ours to
    # assert.
    matched_nationality: str | None = None
    lowered = text.lower()
    for word, signal_id in _NATIONALITIES.items():
        if re.search(rf"\b{word}\b", lowered):
            matched_nationality = signal_id
            break
    country_gated = {"australia", "chile_singapore", "canada_mexico"}
    if matched_nationality:
        found[matched_nationality] = True
        for other in country_gated - {matched_nationality}:
            found[other] = False
    elif _OTHER_NATIONALITIES.search(text):
        for other in country_gated:
            found.setdefault(other, False)

    return found


# ── Ranking ───────────────────────────────────────────────────────────────────

STRONG_THRESHOLD = 0.70
POSSIBLE_THRESHOLD = 0.38

BUCKETS: list[tuple[str, str, str]] = [
    (
        "strong_fit",
        "Strong fit for your situation",
        "Nothing you have told us argues against these, and the main "
        "requirements look like they are met or easily met.",
    ),
    (
        "possible_with_changes",
        "Possible, with changes or more information",
        "Realistic for you, but each turns on something we do not know yet or "
        "something that would have to change — a sponsor, a degree, a role.",
    ),
    (
        "long_shot",
        "Long shot — needs specific circumstances",
        "These need a circumstance you have not described: a particular "
        "nationality, capital to invest, a qualifying employer abroad, or a "
        "protection claim. Listed so you can rule them in or out deliberately, "
        "not because they are likely.",
    ),
]


@dataclass
class ScoredOption:
    node_id: str
    name: str
    score: float
    bucket: str
    reason: str
    open_questions: list[str] = field(default_factory=list)
    work_option: dict = field(default_factory=dict)


def _reason(
    name: str,
    bucket: str,
    met: list[str],
    unknown: list[str],
    blocked: list[str],
    boosts: list[str],
    wo: dict,
) -> str:
    parts: list[str] = []
    if blocked:
        parts.append(
            f"Ranked here because {_join(blocked)} — and {name} generally requires that."
        )
    elif unknown and bucket != "strong_fit":
        parts.append(f"It depends on {_join(unknown)}, which you have not told us yet.")
    elif met:
        parts.append(f"You described {_join(met)}, which is what this route turns on.")
    else:
        parts.append("It has no gating requirement we could not satisfy from what you told us.")

    if boosts:
        parts.append(f"Also in its favour: {_join(boosts)}.")
    if not wo.get("needs_employer_sponsor", True):
        parts.append("No employer sponsor is required for this route.")
    if wo.get("allows_self_petition"):
        parts.append("You can file this one for yourself.")
    if wo.get("country_restricted"):
        parts.append("Restricted by nationality: " + "; ".join(wo["country_restricted"]) + ".")
    return " ".join(parts)


def _join(items: list[str]) -> str:
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + " and " + items[-1]


def score_options(
    graph: PathwayGraph,
    signals: dict[str, bool],
    goal: str = "work_in_us",
) -> list[ScoredOption]:
    """Every node that can serve `goal`, scored and bucketed. Never truncated.

    The scoring is subtractive: an option starts at the `base_fit` its data
    declares and loses ground for each requirement that is unmet or unknown,
    weighted by how much that particular gap matters. Nothing is dropped — an
    option a person cannot use today is still shown, in the bucket that says so,
    because "you do not qualify for this and here is why" is information.
    """
    scored: list[ScoredOption] = []

    for node_id in graph.ids:
        raw = graph.work_option(node_id)
        if not raw or goal not in (raw.get("goals") or []):
            continue

        match = raw.get("match") or {}
        met: list[str] = []
        unknown: list[str] = []
        blocked: list[str] = []
        questions: list[str] = []

        score = float(raw.get("base_fit", 0.0))
        for signal_id in match.get("requires") or []:
            signal = SIGNALS.get(signal_id)
            if signal is None:
                continue
            value = signals.get(signal_id)
            if value is True:
                met.append(signal.label)
            elif value is False:
                blocked.append(f"you do not have {signal.label}")
                score -= signal.false_cost
            else:
                unknown.append(signal.label)
                questions.append(signal.question)
                score -= signal.unknown_cost

        boosted: list[str] = []
        for signal_id in match.get("boosts") or []:
            signal = SIGNALS.get(signal_id)
            if signal is not None and signals.get(signal_id) is True:
                boosted.append(signal.label)
                score += _BOOST

        score = max(0.0, min(1.0, score))
        if blocked:
            bucket = "long_shot"
        elif score >= STRONG_THRESHOLD:
            bucket = "strong_fit"
        elif score >= POSSIBLE_THRESHOLD:
            bucket = "possible_with_changes"
        else:
            bucket = "long_shot"

        node = graph.node(node_id)
        assert node is not None
        scored.append(
            ScoredOption(
                node_id=node_id,
                name=node.name,
                score=round(score, 3),
                bucket=bucket,
                reason=_reason(node.name, bucket, met, unknown, blocked, boosted, raw),
                open_questions=questions[:3],
                work_option=raw,
            )
        )

    order = {b[0]: i for i, b in enumerate(BUCKETS)}
    scored.sort(key=lambda o: (order[o.bucket], -o.score, o.node_id))
    return scored


# ── Assembly ──────────────────────────────────────────────────────────────────


def _to_model(graph: PathwayGraph, scored: ScoredOption) -> PathwayOption:
    wo = scored.work_option
    node = graph.node(scored.node_id)
    return PathwayOption(
        node_id=scored.node_id,
        name=scored.name,
        category=wo.get("option_category", ""),
        summary=wo.get("summary", ""),
        who_it_fits=wo.get("who_it_fits", ""),
        eligibility_signals=list(wo.get("eligibility_signals") or []),
        typical_timeline=wo.get("typical_timeline", ""),
        cost_ballpark=wo.get("cost_ballpark", ""),
        needs_employer_sponsor=bool(wo.get("needs_employer_sponsor", True)),
        allows_self_petition=bool(wo.get("allows_self_petition", False)),
        country_restricted=list(wo.get("country_restricted") or []),
        risk_notes=list(wo.get("risk_notes") or []),
        next_steps=list(wo.get("next_steps") or []),
        parallel_notes=wo.get("parallel_notes"),
        bucket=scored.bucket,
        fit_score=scored.score,
        reason=scored.reason,
        open_questions=scored.open_questions,
        source_hint=node.source_hint if node else "",
    )


def build_option_set(
    graph: PathwayGraph,
    text: str,
    goal_text: str | None = None,
    goal: str | None = None,
) -> PathwayOptionSet | None:
    """The whole answer to a broad goal, or None if no broad goal was described.

    Returning None rather than an empty set matters: it is how the caller knows
    to keep the ordinary single-node intake answer instead of showing somebody
    a landscape they did not ask for.
    """
    goal = goal or detect_goal(text, goal_text)
    if goal not in GOALS:
        return None

    signals = extract_signals(f"{text} {goal_text or ''}")
    scored = score_options(graph, signals, goal)
    options = [_to_model(graph, s) for s in scored]

    buckets = [
        OptionBucket(
            id=bucket_id,
            label=label,
            description=description,
            node_ids=[o.node_id for o in options if o.bucket == bucket_id],
        )
        for bucket_id, label, description in BUCKETS
    ]

    # Deduplicate the open questions, keeping the order the ranking put them in
    # — the highest-ranked option's blockers are asked first.
    seen: set[str] = set()
    questions: list[IntakeQuestion] = []
    by_question = {s.question: s for s in SIGNALS.values()}
    for option in options:
        for text_ in option.open_questions:
            if text_ in seen:
                continue
            seen.add(text_)
            signal = by_question.get(text_)
            questions.append(
                IntakeQuestion(
                    id=f"q_{signal.id}" if signal else f"q_{len(questions)}",
                    text=text_,
                    type="boolean",
                )
            )

    return PathwayOptionSet(
        goal=goal,
        goal_label=GOALS[goal]["label"],
        goal_description=GOALS[goal]["description"],
        options=options,
        buckets=buckets,
        no_employer_needed=[o.node_id for o in options if not o.needs_employer_sponsor],
        self_petition_routes=[o.node_id for o in options if o.allows_self_petition],
        strategy_notes=[
            StrategyNote(
                id=str(n.get("id", "")),
                title=str(n.get("title", "")),
                body=str(n.get("body", "")),
            )
            for n in graph.strategy_notes
        ],
        signals_read=signals,
        questions=questions[:6],
        graph_as_of=graph.as_of,
        disclaimer=graph.disclaimer or DISCLAIMER,
    )
