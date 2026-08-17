"""Does this news item actually touch *you*?

Why this module exists
----------------------
The product promise is "tracks the latest updates, and helps you understand any
changes relevant to YOU". Until now the second half did not exist: the scraper
matched an item to a *node id* and the page printed everything in date order, so
a person on STEM OPT and a person waiting on an EB-2 priority date saw the same
list in the same order. Sorting by date is not personalisation, and "matched to
temp_worker.h1b" is not an explanation.

What this does
--------------
Given one `NewsItem` and one `SituationInput`, it returns a `RelevanceVerdict`:

    affects_you    — this names your status, your form, or your country
    worth_knowing  — this touches where you are trying to go, or your family of
                     statuses, but not you today
    background     — nothing here connects to what you told us

plus a confidence, the list of signals that fired, and two or three plain
sentences addressed to the person.

How it decides — deterministic first
------------------------------------
No model call is required and none is made by default. The scoring reads:

* **Structured Federal Register metadata** (`NewsItem.meta`) — document type,
  agency, CFR references, effective date, comment deadline. This is the reason
  the scraper now asks the API for those fields: "final rule from USCIS
  amending 8 CFR 274a, effective 1 October" is a fact about who a document
  reaches, and it beats any amount of keyword matching on the abstract.
* **Form numbers** — I-129, I-140, I-765, I-539, DS-160 and friends, each
  mapped to the statuses that actually file it.
* **Visa categories** — H-1B, F-1/OPT, L-1, O-1, EB-1…EB-5 and so on.
* **Event kinds** — fee changes, cap and lottery events, processing-time
  changes, policy-manual updates, comment windows. These are amplifiers: a fee
  change matters enormously if it is *your* form and not at all otherwise, so
  they only score alongside a category or form hit.
* **Country-specific items** — TPS designations, per-country backlogs.

Everything the person told us is read through `options.extract_signals` and
`intake`'s keyword table, so there is exactly one place in this codebase that
decides what "I'm on OPT and my employer wants to sponsor me" means.

An LLM pass is available (`RelevanceScorer.refine`) and is strictly additive: it
may rewrite the *wording* of `what_this_means` for the top items, and it may
never change the level, the confidence or the reason. With no API key the
product is unchanged.

Accuracy
--------
Nothing here asserts that a document legally affects anybody. Every phrasing is
"this looks relevant to you because…", every verdict names the concrete signal
that produced it, and every item carries its primary-source URL so the person
can read the original rather than our reading of it. `DISCLAIMER` (shared with
`app/options.py`) rides on every response.

Privacy
-------
`SituationInput` is an argument, never a field. This module holds no state about
a caller, writes nothing, and logs nothing about the situation it was given.
"""

from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass, field
from datetime import date

from .intake import _KEYWORDS as _STATUS_KEYWORDS  # noqa: PLC2701 — see below
from .models import (
    NewsItem,
    RelevanceSignal,
    RelevanceVerdict,
    SituationInput,
)
from .options import DISCLAIMER, extract_signals
from .pathways import load_graph

# `_KEYWORDS` is imported from `intake` on purpose. It is the project's single
# status-vocabulary table ("stem opt" → student.stem_opt), and a second copy
# here would drift the moment somebody adds a status to one and not the other.

log = logging.getLogger("lumos.relevance")

AFFECTS_YOU = "affects_you"
WORTH_KNOWING = "worth_knowing"
BACKGROUND = "background"

LEVELS = (AFFECTS_YOU, WORTH_KNOWING, BACKGROUND)

#: Score at or above which an item is called `affects_you` — and only when at
#: least one signal points at the person's *current* situation rather than their
#: ambition. Ambition alone can never reach the top band.
AFFECTS_THRESHOLD = 0.50
WORTH_KNOWING_THRESHOLD = 0.18


# ── Vocabulary ────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Form:
    """One USCIS/DOS form, and who actually files it."""

    number: str
    #: What the form is, in the words a person would use.
    purpose: str
    nodes: tuple[str, ...]
    pattern: re.Pattern[str]


def _form(number: str, purpose: str, nodes: tuple[str, ...], extra: str = "") -> Form:
    # "I-765", "I 765" and "I765" all appear in government prose.
    stem = number.replace("-", r"[\s-]?")
    body = rf"\b{stem}\b"
    if extra:
        body = f"{body}|{extra}"
    return Form(number, purpose, nodes, re.compile(body, re.I))


FORMS: tuple[Form, ...] = (
    _form(
        "I-129",
        "the petition an employer files to get you a temporary work status",
        ("temp_worker.h1b", "temp_worker.h2a", "temp_worker.h2b", "temp_worker.r1",
         "intracompany.l1", "intracompany.e1", "intracompany.e2", "extraordinary.o1",
         "extraordinary.p1"),
    ),
    _form(
        "I-140",
        "the immigrant petition behind an employment-based green card",
        ("employment_gc.eb1", "employment_gc.eb2", "employment_gc.eb2_niw",
         "employment_gc.eb3"),
    ),
    _form(
        "I-765",
        "the work permit (EAD) application",
        ("student.opt_precompletion", "student.opt_postcompletion", "student.stem_opt",
         "student.cap_gap", "humanitarian.asylum", "humanitarian.tps",
         "family_gc.marriage_aos", "post_lpr.conditional_gc"),
        extra=r"\bemployment authorization document\b|\bEAD\b",
    ),
    _form(
        "I-539",
        "the form for extending or changing a nonimmigrant status, including for "
        "dependents",
        ("student.f1", "exchange.j1", "temp_worker.h1b", "intracompany.l1"),
        extra=r"\bextend(?:ing)? (?:or change|your) status\b|\bchange of status\b",
    ),
    _form(
        "DS-160",
        "the online visa application you complete before a consular interview",
        (),
        extra=r"\bnonimmigrant visa application\b|\bconsular interview\b",
    ),
    _form("DS-2019", "the exchange-visitor certificate your programme issues",
          ("exchange.j1",)),
    _form("I-20", "the school document that carries your F-1 record",
          ("student.f1", "student.cpt", "student.opt_postcompletion",
           "student.stem_opt")),
    _form("I-983", "the STEM OPT training plan you and your employer sign",
          ("student.stem_opt",)),
    _form(
        "I-485",
        "the application to adjust status to permanent residence from inside the US",
        ("family_gc.marriage_aos", "family_gc.immediate_relative",
         "employment_gc.eb1", "employment_gc.eb2", "employment_gc.eb2_niw",
         "employment_gc.eb3", "employment_gc.eb5"),
        extra=r"\badjustment of status\b",
    ),
    _form("I-130", "the family petition a relative files for you",
          ("family_gc.immediate_relative", "family_gc.marriage_aos", "family_gc.f1",
           "family_gc.f2a", "family_gc.f2b", "family_gc.f3", "family_gc.f4")),
    _form("I-131", "the travel document / advance parole application",
          ("family_gc.marriage_aos", "humanitarian.asylum", "humanitarian.parole")),
    _form("I-751", "the petition to remove the conditions on a two-year green card",
          ("post_lpr.conditional_gc",)),
    _form("I-90", "the green card renewal or replacement application",
          ("post_lpr.lpr",)),
    _form("N-400", "the naturalisation application", ("post_lpr.naturalization",)),
    _form("I-589", "the asylum application", ("humanitarian.asylum",)),
    _form("I-526", "the EB-5 investor petition", ("employment_gc.eb5",)),
    _form("I-821", "the TPS application", ("humanitarian.tps",)),
    _form("ETA-9089", "the PERM labour certification your employer files",
          ("employment_gc.eb2", "employment_gc.eb3"),
          extra=r"\bPERM\b|\blabor certification\b"),
    _form("ETA-9035", "the labour condition application (LCA) behind an H-1B",
          ("temp_worker.h1b",), extra=r"\bLCA\b|\blabor condition application\b"),
)


@dataclass(frozen=True)
class Category:
    """A visa category as a person names it, and the nodes it covers."""

    id: str
    label: str
    nodes: tuple[str, ...]
    pattern: re.Pattern[str]


def _cat(id_: str, label: str, nodes: tuple[str, ...], pattern: str) -> Category:
    return Category(id_, label, nodes, re.compile(pattern, re.I))


CATEGORIES: tuple[Category, ...] = (
    _cat("f1", "F-1 student status",
         ("student.f1", "student.cpt", "student.opt_precompletion"),
         r"\bF[\s-]?1\b|\bstudent visa\b|\bSEVIS\b|\bSEVP\b|\bF[\s-]?1 student"),
    _cat("cpt", "CPT", ("student.cpt",), r"\bCPT\b|\bcurricular practical training\b"),
    _cat("opt", "OPT", ("student.opt_postcompletion", "student.opt_precompletion"),
         r"\bOPT\b|\boptional practical training\b|\bpost[\s-]?completion\b"),
    _cat("stem_opt", "STEM OPT", ("student.stem_opt",),
         r"\bSTEM OPT\b|\b24[\s-]month extension\b|\bSTEM designated degree\b"),
    _cat("cap_gap", "cap-gap", ("student.cap_gap",), r"\bcap[\s-]?gap\b"),
    _cat("h1b", "H-1B", ("temp_worker.h1b", "student.cap_gap"),
         r"\bH[\s-]?1B\b|\bspecialty occupation\b"),
    _cat("h2a", "H-2A", ("temp_worker.h2a",), r"\bH[\s-]?2A\b"),
    _cat("h2b", "H-2B", ("temp_worker.h2b",), r"\bH[\s-]?2B\b"),
    _cat("h4", "H-4", ("temp_worker.h1b",), r"\bH[\s-]?4\b"),
    _cat("l1", "L-1", ("intracompany.l1",), r"\bL[\s-]?1[AB]?\b|\bintracompany\b"),
    _cat("o1", "O-1", ("extraordinary.o1",),
         r"\bO[\s-]?1[AB]?\b|\bextraordinary ability\b"),
    _cat("p1", "P-1", ("extraordinary.p1",), r"\bP[\s-]?1\b"),
    _cat("j1", "J-1", ("exchange.j1",),
         r"\bJ[\s-]?1\b|\bexchange visitor\b|\b212\(e\)\b"),
    _cat("e2", "E-2", ("intracompany.e2",), r"\bE[\s-]?2\b|\btreaty investor\b"),
    _cat("e1", "E-1", ("intracompany.e1",), r"\bE[\s-]?1\b|\btreaty trader\b"),
    _cat("e3", "E-3", ("intracompany.e1",), r"\bE[\s-]?3\b"),
    _cat("tn", "TN", ("intracompany.tn",), r"\bTN\b|\bUSMCA\b|\bNAFTA\b"),
    _cat("r1", "R-1", ("temp_worker.r1",), r"\bR[\s-]?1\b|\breligious worker\b"),
    _cat("eb1", "EB-1", ("employment_gc.eb1",), r"\bEB[\s-]?1\b|\bpriority worker\b"),
    _cat("eb2", "EB-2", ("employment_gc.eb2",), r"\bEB[\s-]?2\b"),
    _cat("niw", "EB-2 NIW", ("employment_gc.eb2_niw",),
         r"\bnational interest waiver\b|\bNIW\b|\bDhanasar\b"),
    _cat("eb3", "EB-3", ("employment_gc.eb3",), r"\bEB[\s-]?3\b|\bskilled worker\b"),
    _cat("eb4", "EB-4", ("employment_gc.eb4",), r"\bEB[\s-]?4\b"),
    _cat("eb5", "EB-5", ("employment_gc.eb5",),
         r"\bEB[\s-]?5\b|\bregional cent(?:er|re)\b"),
    _cat("visa_bulletin", "the Visa Bulletin and priority dates",
         ("employment_gc.eb1", "employment_gc.eb2", "employment_gc.eb2_niw",
          "employment_gc.eb3", "employment_gc.eb5", "family_gc.f1", "family_gc.f2a",
          "family_gc.f2b", "family_gc.f3", "family_gc.f4"),
         r"\bvisa bulletin\b|\bpriority date\b|\bretrogress\w*|\bfinal action date\b|"
         r"\bannual limit\b|\bper[\s-]country (?:limit|cap)\b"),
    _cat("marriage_gc", "a marriage-based green card",
         ("family_gc.marriage_aos", "family_gc.immediate_relative"),
         r"\bmarriage[\s-]based\b|\bimmediate relative\b|\bconditional resident\b"),
    _cat("naturalization", "naturalisation", ("post_lpr.naturalization",),
         r"\bnaturaliz\w*|\bcitizenship (?:test|application|ceremony)\b|"
         r"\bcivics test\b"),
    _cat("lpr", "permanent residence", ("post_lpr.lpr", "post_lpr.conditional_gc"),
         r"\bgreen card\b|\blawful permanent resident\b|\bLPR\b"),
    _cat("asylum", "asylum", ("humanitarian.asylum",), r"\basylum\b|\basylee\b"),
    _cat("tps", "Temporary Protected Status", ("humanitarian.tps",),
         r"\btemporary protected status\b|\bTPS\b"),
    _cat("parole", "humanitarian parole", ("humanitarian.parole",),
         r"\bhumanitarian parole\b|\bparole program\w*"),
    _cat("refugee", "refugee admissions", ("humanitarian.refugee",), r"\brefugee\b"),
    _cat("dv", "the diversity visa lottery", ("diversity.dv",),
         r"\bdiversity visa\b|\bDV[\s-]?\d{4}\b|\bgreen card lottery\b"),
)

CATEGORIES_BY_ID = {c.id: c for c in CATEGORIES}


@dataclass(frozen=True)
class Event:
    """A *kind of change*, rather than a population.

    These are amplifiers, never a match on their own. A fee change is the most
    important thing in the world if it is your form and completely irrelevant
    otherwise, so scoring one without a category or form hit would be exactly
    the naive keyword ranking this module exists to replace.
    """

    id: str
    #: Filled into "It is a …" in the explanation.
    phrase: str
    weight: float
    pattern: re.Pattern[str]


def _event(id_: str, phrase: str, weight: float, pattern: str) -> Event:
    return Event(id_, phrase, weight, re.compile(pattern, re.I))


EVENTS: tuple[Event, ...] = (
    _event("fee", "a change to filing fees", 0.16,
           r"\bfee schedule\b|\bfiling fee\w*|\bfee (?:increase|change|adjustment)\b|"
           r"\bfees? for\b|\bbiometric services fee\b"),
    _event("cap", "a cap or lottery event", 0.20,
           r"\bcap\b|\blotter\w+|\brandom selection\b|\bregistration period\b|"
           r"\belectronic registration\b|\bcap season\b|\bnumerical limit\w*|"
           r"\bcap[\s-]?exempt\b"),
    _event("processing_time", "a change to how long filings take", 0.14,
           r"\bprocessing time\w*|\bpremium processing\b|\bbacklog\w*|"
           r"\badjudicat\w+ (?:time|delay)\w*|\bexpedite\b"),
    _event("policy_manual", "a Policy Manual update", 0.12,
           r"\bpolicy manual\b|\bpolicy (?:alert|guidance|memorandum)\b|\bUSCIS PM\b"),
    _event("form_edition", "a new edition of a form", 0.10,
           r"\bnew edition\b|\bedition date\b|\brevised form\b|\bform (?:update|revision)\b"),
    _event("evidence", "a change to what evidence is required", 0.10,
           r"\brequest for evidence\b|\bRFE\b|\bevidentiary (?:standard|requirement)\w*|"
           r"\bdocumentary requirement\w*"),
    _event("comment_window", "an open comment period you could write into", 0.08,
           r"\bcomments? (?:must be received|are invited|due)\b|\bcomment period\b|"
           r"\brequest for (?:public )?comment\b"),
)


#: Countries that show up as the *subject* of an immigration item — TPS
#: designations, per-country backlogs, travel restrictions. Matching is only
#: ever used to raise an item for somebody who named the same country; a
#: country we do not recognise simply produces no country signal.
COUNTRIES: tuple[str, ...] = (
    "India", "China", "Mexico", "Philippines", "Vietnam", "Brazil", "Colombia",
    "Venezuela", "Cuba", "Haiti", "Nicaragua", "Honduras", "El Salvador",
    "Guatemala", "Ukraine", "Russia", "Afghanistan", "Syria", "Yemen", "Somalia",
    "Sudan", "South Sudan", "Ethiopia", "Eritrea", "Nigeria", "Ghana", "Kenya",
    "Cameroon", "Myanmar", "Burma", "Nepal", "Pakistan", "Bangladesh", "Sri Lanka",
    "Iran", "Iraq", "Lebanon", "Turkey", "Egypt", "Israel", "Canada", "Australia",
    "Chile", "Singapore", "South Korea", "Japan", "Taiwan", "Indonesia", "Thailand",
    "Nigeria", "Zimbabwe", "Cambodia", "Laos", "Hong Kong",
)
_COUNTRY_PATTERNS: dict[str, re.Pattern[str]] = {
    name: re.compile(rf"\b{re.escape(name)}\b", re.I) for name in COUNTRIES
}

#: CFR parts, and the plain-English population each one reaches. Only used when
#: the Federal Register gave us the reference — never inferred from prose.
CFR_MEANING: dict[str, tuple[str, tuple[str, ...]]] = {
    "8 CFR 214": (
        "the rules for temporary (nonimmigrant) statuses",
        ("student.f1", "student.cpt", "student.opt_postcompletion",
         "student.stem_opt", "student.cap_gap", "temp_worker.h1b", "temp_worker.h2a",
         "temp_worker.h2b", "temp_worker.r1", "intracompany.l1", "intracompany.e1",
         "intracompany.e2", "extraordinary.o1", "extraordinary.p1", "exchange.j1"),
    ),
    "8 CFR 274a": (
        "the rules for employment authorisation and work permits",
        ("student.opt_postcompletion", "student.stem_opt", "student.cap_gap",
         "humanitarian.asylum", "humanitarian.tps", "family_gc.marriage_aos"),
    ),
    "8 CFR 204": (
        "the rules for immigrant petitions",
        ("employment_gc.eb1", "employment_gc.eb2", "employment_gc.eb2_niw",
         "employment_gc.eb3", "employment_gc.eb5", "family_gc.immediate_relative",
         "family_gc.marriage_aos"),
    ),
    "8 CFR 245": (
        "the rules for adjusting status inside the US",
        ("family_gc.marriage_aos", "family_gc.immediate_relative",
         "employment_gc.eb1", "employment_gc.eb2", "employment_gc.eb2_niw",
         "employment_gc.eb3"),
    ),
    "8 CFR 106": ("the USCIS fee schedule", ()),
    "8 CFR 103": ("USCIS filing and adjudication procedure", ()),
    "8 CFR 316": ("the naturalisation requirements", ("post_lpr.naturalization",)),
    "8 CFR 244": ("Temporary Protected Status", ("humanitarian.tps",)),
    "8 CFR 208": ("the asylum rules", ("humanitarian.asylum",)),
    "20 CFR 655": (
        "the Department of Labor's rules for hiring foreign workers",
        ("temp_worker.h1b", "temp_worker.h2a", "temp_worker.h2b",
         "employment_gc.eb2", "employment_gc.eb3"),
    ),
    "22 CFR 41": ("the State Department's nonimmigrant visa rules", ()),
    "22 CFR 42": ("the State Department's immigrant visa rules", ()),
}

#: Agency slug → how a person would name it.
AGENCY_NAMES: dict[str, str] = {
    "u-s-citizenship-and-immigration-services": "USCIS",
    "homeland-security-department": "the Department of Homeland Security",
    "state-department": "the State Department",
    "employment-and-training-administration": "the Department of Labor",
    "labor-department": "the Department of Labor",
    "executive-office-for-immigration-review": "the immigration courts",
    "customs-and-border-protection": "CBP",
}


# ── Reading the person ────────────────────────────────────────────────────────


@dataclass
class Reader:
    """What we believe about the person, for the length of one request.

    Split into "now" and "next" because the distinction is the whole product:
    a change to H-1B registration *affects* somebody on H-1B and is merely
    *worth knowing* for a student who hopes to file one day. Conflating them is
    how a feed ends up shouting at everybody about everything.
    """

    now_nodes: set[str] = field(default_factory=set)
    goal_nodes: set[str] = field(default_factory=set)
    now_categories: set[str] = field(default_factory=set)
    goal_categories: set[str] = field(default_factory=set)
    forms: set[str] = field(default_factory=set)
    countries: set[str] = field(default_factory=set)

    #: `options.extract_signals` output — the same reading the option ranker uses.
    signals: dict[str, bool] = field(default_factory=dict)

    #: When their status next changes, in words. Empty when they did not say.
    change_note: str = ""

    @property
    def is_blank(self) -> bool:
        return not (
            self.now_nodes
            or self.goal_nodes
            or self.now_categories
            or self.goal_categories
        )

    @property
    def all_nodes(self) -> set[str]:
        return self.now_nodes | self.goal_nodes


def _nodes_from_text(text: str) -> set[str]:
    """Every status the text names, via `intake`'s keyword table.

    `intake._match` returns the single best match because intake places somebody
    at one point on the map. Relevance wants the whole set — somebody who writes
    "I'm on STEM OPT hoping for H-1B" is touched by news about both — so this
    walks the same table and collects everything.
    """
    return {node_id for pattern, node_id in _STATUS_KEYWORDS if pattern.search(text)}


def _categories_from_text(text: str) -> set[str]:
    return {c.id for c in CATEGORIES if c.pattern.search(text)}


def _countries_from_text(text: str) -> set[str]:
    return {name for name, pattern in _COUNTRY_PATTERNS.items() if pattern.search(text)}


_MONTHS = (
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
)


def read_situation(situation: SituationInput) -> Reader:
    """Turn what the client sent into the sets the scorer compares against.

    Nothing is invented. A field the person did not fill in produces no signal,
    and an empty situation produces a `Reader` that scores everything as
    `background` — which is the honest answer and is what makes the endpoint
    degrade to a plain chronological list.
    """
    status_text = situation.status_text or ""
    goal_text = situation.goal_text or ""

    reader = Reader(
        signals=extract_signals(f"{status_text} {goal_text}".strip()),
    )

    reader.now_nodes = _nodes_from_text(status_text)
    reader.goal_nodes = _nodes_from_text(goal_text)
    if situation.current_node_id:
        reader.now_nodes.add(situation.current_node_id)
    if situation.goal_node_id:
        reader.goal_nodes.add(situation.goal_node_id)
    # Extra node ids are routes the person is considering, not where they are.
    reader.goal_nodes.update(situation.node_ids)
    # A node cannot be both; being somewhere wins over aiming at it.
    reader.goal_nodes -= reader.now_nodes

    reader.now_categories = _categories_from_text(status_text)
    reader.goal_categories = _categories_from_text(goal_text) - reader.now_categories

    # Categories implied by a resolved node id, so a client that sends only
    # `current_node_id` gets the same quality of match as one that sends prose.
    for category in CATEGORIES:
        if reader.now_nodes & set(category.nodes):
            reader.now_categories.add(category.id)
        elif reader.goal_nodes & set(category.nodes):
            reader.goal_categories.add(category.id)
    reader.goal_categories -= reader.now_categories

    # The forms this person plausibly files, from their nodes.
    reader.forms = {
        form.number
        for form in FORMS
        if form.nodes and reader.all_nodes & set(form.nodes)
    }

    reader.countries = _countries_from_text(f"{status_text} {goal_text}")
    if situation.country:
        reader.countries |= _countries_from_text(situation.country)

    if situation.change_year:
        month = situation.change_month
        if month and 1 <= month <= 12:
            reader.change_note = f"{_MONTHS[month - 1]} {situation.change_year}"
        else:
            reader.change_note = str(situation.change_year)

    return reader


# ── Reading the item ──────────────────────────────────────────────────────────


def node_label(node_id: str) -> str:
    """A node id as a person would say it: `student.stem_opt` → "STEM OPT
    Extension".

    Node ids are internal plumbing. Printing one in a sentence addressed to
    somebody worried about their status is the kind of thing that makes a
    product feel like it was written for its own database, so every id that
    reaches the copy goes through here. An id the graph does not know falls back
    to a readable form rather than disappearing.
    """
    try:
        node = load_graph().node(node_id)
    except Exception:  # noqa: BLE001 — a missing graph must not break the feed
        node = None
    if node is not None:
        return node.name
    return node_id.split(".", 1)[-1].replace("_", " ")


@dataclass
class _Hit:
    """One matched signal, before it becomes a `RelevanceSignal`.

    `tier` is the field the public model does not need: it records whether the
    match was against where the person *is* (`now`), where they are *going*
    (`goal`), or neither (`general`). Only a `now` hit can push an item into
    `affects_you`.
    """

    kind: str
    label: str
    found_in: str
    weight: float
    tier: str = "general"
    #: Used to build the explanation; not serialised.
    detail: str = ""
    #: How this hit is named in a sentence. Differs from `label` for nodes,
    #: where `label` stays the machine id so the signal list is auditable.
    display: str = ""

    def __post_init__(self) -> None:
        if not self.display:
            self.display = self.label


def _haystacks(item: NewsItem) -> dict[str, str]:
    """The text of an item, kept per-field so a signal can say where it was."""
    return {
        "title": item.title or "",
        "summary": item.summary or "",
        "metadata": " ".join(
            [item.meta.action, item.meta.document_type, *item.meta.docket_ids]
        ),
    }


def _find(patterns_text: dict[str, str], pattern: re.Pattern[str]) -> str | None:
    """Which field a pattern matched in, most authoritative first."""
    for field_name in ("title", "metadata", "summary"):
        if pattern.search(patterns_text.get(field_name, "")):
            return field_name
    return None


def collect_hits(item: NewsItem, reader: Reader) -> list[_Hit]:
    """Every reason this item might matter to this person, with a weight each.

    Ordering of the checks is not significant — the caller sorts by weight — but
    the *tiers* are: `now` hits are what separate "this is about you" from "this
    is about a route you mentioned".
    """
    text = _haystacks(item)
    hits: list[_Hit] = []

    # 1. Node overlap. The scraper already matched every item to pathway nodes,
    #    so this is the cheapest and most direct signal available.
    matched = set(item.matched_nodes)
    for node_id in sorted(matched & reader.now_nodes):
        hits.append(
            _Hit("node", node_id, "matched_nodes", 0.45, "now",
                 detail="the status you are on now", display=node_label(node_id))
        )
    for node_id in sorted(matched & reader.goal_nodes):
        hits.append(
            _Hit("node", node_id, "matched_nodes", 0.20, "goal",
                 detail="a route you said you are aiming for",
                 display=node_label(node_id))
        )

    # 2. Visa categories named in the document itself.
    for category in CATEGORIES:
        if category.id in reader.now_categories:
            weight, tier = 0.40, "now"
        elif category.id in reader.goal_categories:
            weight, tier = 0.18, "goal"
        else:
            continue
        where = _find(text, category.pattern)
        if where:
            hits.append(
                _Hit("category", category.label, where, weight, tier,
                     detail=category.label)
            )

    # 3. Form numbers. A person recognises "I-765" far faster than a node id,
    #    and a form is a concrete thing they either file or do not.
    for form in FORMS:
        where = _find(text, form.pattern)
        if not where:
            continue
        if form.number in reader.forms:
            hits.append(
                _Hit("form", f"Form {form.number}", where, 0.35, "now",
                     detail=form.purpose)
            )
        elif not form.nodes and not reader.signals.get("in_us", True):
            # Consular forms (DS-160) reach anybody applying from outside the
            # US, which is exactly who has no status to match on.
            hits.append(
                _Hit("form", f"Form {form.number}", where, 0.22, "now",
                     detail=form.purpose)
            )

    # 4. CFR parts, straight from the Federal Register record. Structured, so it
    #    is trusted more than the same claim made in prose.
    for ref in item.meta.cfr_references:
        meaning = CFR_MEANING.get(ref)
        if meaning is None:
            continue
        description, nodes = meaning
        if nodes and reader.all_nodes & set(nodes):
            tier = "now" if reader.now_nodes & set(nodes) else "goal"
            hits.append(
                _Hit("cfr", ref, "cfr", 0.24 if tier == "now" else 0.12, tier,
                     detail=description)
            )

    # 5. Country-specific items — TPS designations, per-country backlogs.
    #
    #
    #    A country in the *headline* means the document is scoped by
    #    nationality — a TPS designation, a travel restriction, a per-country
    #    limit — and nationality is a present fact about somebody, not an
    #    ambition. That is enough on its own to reach `affects_you`, because
    #    such a document reaches a person whatever status they hold.
    #
    #    A country mentioned further down is weaker and inherits the tier of
    #    whatever else matched, so "India" in the body of a bulletin does not
    #    promote a green-card hope into "this affects you".
    inherited_tier = "now" if any(h.tier == "now" for h in hits) else "goal"
    for country in sorted(reader.countries):
        pattern = _COUNTRY_PATTERNS.get(country)
        if pattern is None:
            continue
        where = _find(text, pattern)
        if where == "title":
            hits.append(
                _Hit("country", country, where, 0.50, "now",
                     detail="the country you told us about")
            )
        elif where:
            hits.append(
                _Hit("country", country, where,
                     0.28 if inherited_tier == "now" else 0.16, inherited_tier,
                     detail="the country you told us about")
            )

    # 6. Event kinds — amplifiers only. Without a population hit above, a fee
    #    change is somebody else's fee change.
    has_population_hit = any(h.kind in {"node", "category", "form", "cfr"} for h in hits)
    for event in EVENTS:
        where = _find(text, event.pattern)
        if not where:
            continue
        if not has_population_hit:
            continue
        hits.append(
            _Hit(event.id, event.phrase, where, event.weight, "general",
                 detail=event.phrase)
        )

    # 7. Document type, from metadata. A final rule is a change that has
    #    happened; a proposed rule is one that might. That belongs in
    #    confidence, so the weights are small and deliberately so.
    doc_type = (item.meta.document_type or "").lower()
    if has_population_hit and doc_type:
        if doc_type == "rule":
            hits.append(
                _Hit("document_type", "a final rule", "metadata", 0.08, "general",
                     detail="")
            )
        elif doc_type == "proposed rule":
            hits.append(
                _Hit("document_type", "a proposed rule", "metadata", 0.04, "general",
                     # The single most important caveat we can add: a proposal
                     # is not a change, and people act on headlines about them.
                     detail="Nothing has changed yet — a proposed rule is a "
                     "plan the agency is asking for comment on.")
            )
        elif doc_type == "presidential document":
            hits.append(
                _Hit("document_type", "a presidential document", "metadata", 0.08,
                     "general", detail="")
            )

    # 8. Agency alone. Never enough on its own — it is the difference between
    #    `background` and nothing, not between `background` and `affects_you`.
    for slug in item.meta.agencies:
        name = AGENCY_NAMES.get(slug)
        if name and not has_population_hit:
            hits.append(
                _Hit("agency", name, "metadata", 0.05, "general",
                     detail=f"it comes from {name}")
            )
            break

    return sorted(hits, key=lambda h: -h.weight)


def _deadlines(item: NewsItem, reader: Reader, relevant: bool) -> list[str]:
    """Dates on this item that could move the person's own timeline.

    Only reported when the item is relevant at all — an effective date on a
    document about somebody else's status is not the person's deadline, and
    printing it as one would be manufacturing a deadline out of nothing.
    """
    if not relevant:
        return []

    notes: list[str] = []
    if item.meta.effective_on:
        note = f"Takes effect {_pretty(item.meta.effective_on)}"
        if reader.change_note:
            note += f" — your status changes around {reader.change_note}"
        notes.append(note + ".")
    if item.meta.comments_close_on:
        notes.append(
            f"Public comments close {_pretty(item.meta.comments_close_on)}, "
            "if you want to write in."
        )
    return notes


def _pretty(value: date) -> str:
    return f"{_MONTHS[value.month - 1]} {value.day}, {value.year}"


# ── Verdict ───────────────────────────────────────────────────────────────────


def _level(score: float, hits: list[_Hit]) -> str:
    """Band an item, with one hard rule layered on the score.

    The rule: nothing reaches `affects_you` on ambition alone. An item can score
    highly off a person's goal routes — a green-card hopeful matches half the
    Federal Register — and calling that "affects you" is the exact overreach
    this module is meant to prevent.
    """
    has_now = any(h.tier == "now" for h in hits)
    if score >= AFFECTS_THRESHOLD and has_now:
        return AFFECTS_YOU
    if score >= WORTH_KNOWING_THRESHOLD:
        return WORTH_KNOWING
    return BACKGROUND


def _reason(hits: list[_Hit], level: str) -> str:
    """The concrete signal that produced the level. Never empty, never vague."""
    if not hits:
        return (
            "Nothing in this item named your status, the forms you file, or your "
            "country."
        )

    top = hits[0]
    where = {
        "title": "in the headline",
        "summary": "in the abstract",
        "metadata": "in the publisher's own metadata",
        "matched_nodes": "when it was filed",
        "cfr": "in the regulations it amends",
    }.get(top.found_in, "in the document")

    if top.kind == "node":
        subject = "your current status" if top.tier == "now" else "a route you named"
        base = f"Matched to {top.display} — {subject} — {where}."
    elif top.kind == "category":
        base = f"It names {top.display} {where}, which is part of your situation."
    elif top.kind == "form":
        base = f"It names {top.display} {where} — {top.detail}."
    elif top.kind == "cfr":
        base = f"It amends {top.display}, {top.detail}."
    elif top.kind == "country":
        base = f"It names {top.display} {where}, the country you told us about."
    elif top.kind == "agency":
        base = f"It comes from {top.display}, but nothing in it named your situation."
    else:
        base = f"It is {top.display}, {where}."

    if level == BACKGROUND and top.kind != "agency":
        base += " That is a weak link on its own, so it is filed as background."
    return base


def _what_this_means(
    item: NewsItem, reader: Reader, hits: list[_Hit], level: str, deadlines: list[str]
) -> str:
    """Two or three sentences, second person, concrete, and never a legal claim.

    Deliberately hedged: "looks relevant", "you would file", "read the original".
    This is a metadata match on a public document, and the copy has to carry
    that honestly — somebody making a filing decision off a sentence we wrote is
    the failure mode that matters here.
    """
    if level == BACKGROUND:
        agency = next((h.display for h in hits if h.kind == "agency"), None)
        source = agency or item.source_name
        return (
            f"Nothing in this one points at your situation — it does not name "
            f"your status, the forms you file, or your country. It is here from "
            f"{source} so the record is complete, not because you need to act on "
            f"it. Informational only, not legal advice."
        )

    # Sentence 1 — why it surfaced, in the person's terms.
    populations = [h for h in hits if h.kind in {"node", "category", "form", "cfr", "country"}]
    lead_parts: list[str] = []
    for hit in populations:
        if len(lead_parts) >= 2:
            break
        # "EB-2 — PERM route" and "EB-2" are the same news to a reader, even
        # though one came from a node id and the other from the prose. Naming
        # both makes the sentence look automated, which is the impression this
        # whole module is trying to avoid.
        if any(
            hit.display.lower() in existing.lower()
            or existing.lower().startswith(hit.display.lower())
            for existing in lead_parts
        ):
            continue
        if hit.kind == "form":
            lead_parts.append(f"{hit.display}, {hit.detail}")
        elif hit.kind == "cfr":
            lead_parts.append(f"{hit.display} — {hit.detail}")
        else:
            lead_parts.append(hit.display)

    if lead_parts:
        first = (
            "This looks relevant to you because it touches "
            + _join(lead_parts)
            + "."
        )
    else:
        first = "This looks relevant to you because it touches the area you described."

    # Sentence 2 — what kind of document it is and what kind of change it
    # carries, read off the structured record rather than guessed from prose.
    events = [h for h in hits if h.kind in {e.id for e in EVENTS}]
    doc = next((h for h in hits if h.kind == "document_type"), None)
    agency = next(
        (AGENCY_NAMES[s] for s in item.meta.agencies if s in AGENCY_NAMES), None
    )
    who = f" from {agency}" if agency else ""
    event_phrase = _join([h.display for h in events[:2]])

    if doc and event_phrase:
        second = f"It is {doc.display}{who}, and it involves {event_phrase}."
    elif doc:
        second = f"It is {doc.display}{who}."
    elif event_phrase:
        source = agency or item.source_name
        second = f"It comes from {source} and involves {event_phrase}."
    elif agency:
        second = f"It comes from {agency}."
    else:
        second = f"It was published by {item.source_name}."

    # A proposed rule gets the caveat spelled out, because headlines about
    # proposals read exactly like headlines about changes.
    if doc is not None and doc.detail:
        second = f"{second} {doc.detail}"

    # Sentence 3 — the date that could move their plans, or the honest caveat.
    if deadlines:
        third = deadlines[0]
    elif level == WORTH_KNOWING:
        third = (
            "It points at where you are trying to go rather than where you are "
            "today, so it is worth reading but not something to act on yet."
        )
    else:
        third = "No effective date was published with it."

    closing = (
        "Read the original before acting on it — this is a match on what the "
        "document says, not legal advice."
    )
    return " ".join([first, second, third, closing])


def _join(items: list[str]) -> str:
    items = [i for i in items if i]
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + " and " + items[-1]


def score_item(item: NewsItem, reader: Reader) -> RelevanceVerdict:
    """One item against one person. Pure, deterministic, no I/O.

    Same inputs always give the same verdict, which is what makes the ranking
    auditable — and what lets the whole feature work with no API key at all.
    """
    if reader.is_blank:
        # We know nothing about this person, so nothing can be said to be about
        # them. Saying so is better than ranking on a guess.
        return RelevanceVerdict(
            level=BACKGROUND,
            confidence=0.0,
            reason="You have not told us your situation yet, so nothing is "
            "matched to you.",
            what_this_means=(
                "We cannot say whether this touches you, because we do not know "
                "what status you are on or what you are aiming for. Tell us your "
                "situation and this list will re-sort around it. Informational "
                "only, not legal advice."
            ),
        )

    hits = collect_hits(item, reader)
    score = min(1.0, sum(h.weight for h in hits))
    level = _level(score, hits)
    deadlines = _deadlines(item, reader, level != BACKGROUND)

    touches = sorted(
        {h.label for h in hits if h.kind == "node"}
        | (set(item.matched_nodes) & reader.all_nodes)
    )

    return RelevanceVerdict(
        level=level,
        confidence=round(score, 3),
        reason=_reason(hits, level),
        what_this_means=_what_this_means(item, reader, hits, level, deadlines),
        signals=[
            RelevanceSignal(
                kind=h.kind, label=h.label, found_in=h.found_in, weight=round(h.weight, 3)
            )
            for h in hits
        ],
        touches_nodes=touches,
        touches_deadlines=deadlines,
    )


_LEVEL_ORDER = {AFFECTS_YOU: 0, WORTH_KNOWING: 1, BACKGROUND: 2}


def rank(
    items: list[NewsItem], situation: SituationInput
) -> list[tuple[NewsItem, RelevanceVerdict]]:
    """Score every item and sort `affects_you` first, then by confidence, then
    by date. Nothing is dropped: a person is entitled to see the whole feed,
    just not in the order the publisher happened to publish it."""
    reader = read_situation(situation)
    scored = [(item, score_item(item, reader)) for item in items]
    scored.sort(
        key=lambda pair: (
            _LEVEL_ORDER.get(pair[1].level, 3),
            -pair[1].confidence,
            # Newest first inside a band. `first_seen_at` always exists;
            # `published_at` often does not.
            -(pair[0].published_at or pair[0].first_seen_at).timestamp(),
        )
    )
    return scored


def counts(verdicts: list[RelevanceVerdict]) -> dict[str, int]:
    """One count per level, always all three keys — an empty `affects_you` is
    itself the answer and the UI needs to be able to say so."""
    tally = {level: 0 for level in LEVELS}
    for verdict in verdicts:
        tally[verdict.level] = tally.get(verdict.level, 0) + 1
    return tally


# ── Optional LLM refinement ───────────────────────────────────────────────────

MODEL = os.getenv("RELEVANCE_MODEL", "claude-opus-5")

#: A rewrite of three short paragraphs over facts already established. There is
#: no reasoning to buy here.
EFFORT = os.getenv("RELEVANCE_EFFORT", "low")

_REFINE_SYSTEM = """\
You rewrite one short explanation for Lumos, a US immigration tracker.

You are given a government document, a person's situation in their own words, \
and a deterministic verdict about why the document looks relevant to them. The \
verdict has already been decided. Your only job is to make the "what this \
means for you" paragraph clearer and more concrete.

Rules, all of them hard:
- 2 to 3 sentences. Second person. Plain words, no jargon a person would have \
to look up.
- Say only what the document and the listed signals support. Never add a fee \
amount, a date, a deadline, a processing time or an eligibility rule that is \
not in the material given to you.
- Never say the document affects them, changes their status, or requires \
anything of them. Say it "looks relevant" and why.
- No legal advice, no predictions about whether anything will be approved.
- End by pointing them at the original document.
Return only the paragraph, no preamble.
"""


class RelevanceScorer:
    """The deterministic scorer, plus an optional LLM polish on the wording.

    The split matters. `rank` is the product: it needs no key, no network and no
    budget, and it is what runs in every deployment. `refine` is a wording
    improvement on the handful of items a person will actually read, and if it
    fails — no key, rate limit, refusal — the deterministic sentences are
    already in place and nothing is lost.
    """

    #: Refining every item would be slow and pointless; only the top band is
    #: ever read closely.
    MAX_REFINED = 5

    def __init__(self) -> None:
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
            log.warning("relevance refiner unavailable (%s)", self._client_error)

    @property
    def llm_available(self) -> bool:
        return self._client is not None

    def rank(
        self, items: list[NewsItem], situation: SituationInput
    ) -> list[tuple[NewsItem, RelevanceVerdict]]:
        return rank(items, situation)

    async def refine(
        self,
        scored: list[tuple[NewsItem, RelevanceVerdict]],
        situation: SituationInput,
    ) -> bool:
        """Rewrite `what_this_means` on the top `affects_you` items, in place.

        Returns whether anything was rewritten. The level, confidence, reason
        and signals are untouched by design — a model may improve prose, but it
        may not decide what is relevant to somebody's immigration status.
        """
        if self._client is None:
            return False

        targets = [
            pair for pair in scored if pair[1].level == AFFECTS_YOU
        ][: self.MAX_REFINED]
        if not targets:
            return False

        refined = False
        for item, verdict in targets:
            try:
                text = await self._refine_one(item, verdict, situation)
            except Exception:  # noqa: BLE001
                # Deliberately not logging the situation or the exception body:
                # the request carries the person's own words.
                log.warning("relevance refinement failed; keeping the written text")
                continue
            if text:
                verdict.what_this_means = text
                verdict.explained_by = "deterministic+llm"
                refined = True
        return refined

    async def _refine_one(
        self,
        item: NewsItem,
        verdict: RelevanceVerdict,
        situation: SituationInput,
    ) -> str | None:
        assert self._client is not None

        signals = "\n".join(
            f"- {s.kind}: {s.label} (found in {s.found_in})" for s in verdict.signals
        )
        prompt = (
            f"Document title: {item.title}\n"
            f"Publisher: {item.source_name}\n"
            f"Document type: {item.meta.document_type or 'unknown'}\n"
            f"Abstract: {item.summary or '(none)'}\n"
            f"Effective date: {item.meta.effective_on or 'not published'}\n"
            f"Source URL: {item.url}\n\n"
            f"Their situation: {situation.status_text or '(not given)'}\n"
            f"What they want next: {situation.goal_text or '(not given)'}\n\n"
            f"Signals that matched:\n{signals}\n\n"
            f"Deterministic reason: {verdict.reason}\n"
            f"Current paragraph: {verdict.what_this_means}\n\n"
            "Rewrite the paragraph."
        )

        response = await self._client.messages.create(
            model=MODEL,
            max_tokens=1200,
            system=[
                {
                    "type": "text",
                    "text": _REFINE_SYSTEM,
                    # Identical on every call and much larger than the payload.
                    "cache_control": {"type": "ephemeral"},
                }
            ],
            output_config={"effort": EFFORT},
            messages=[{"role": "user", "content": prompt}],
        )
        if response.stop_reason == "refusal":
            return None
        text = next((b.text for b in response.content if b.type == "text"), "")
        text = " ".join(text.split())
        # A runaway response is a worse explanation than the one we wrote.
        return text if 0 < len(text) <= 900 else None


__all__ = [
    "AFFECTS_YOU",
    "BACKGROUND",
    "DISCLAIMER",
    "LEVELS",
    "WORTH_KNOWING",
    "Reader",
    "RelevanceScorer",
    "collect_hits",
    "counts",
    "rank",
    "read_situation",
    "score_item",
]
