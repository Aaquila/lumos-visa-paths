"""Wire formats shared by the scraper, the store and the API."""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone

from pydantic import BaseModel, Field, HttpUrl


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class NewsItem(BaseModel):
    """One scraped update from a curated source."""

    id: str = Field(description="Stable hash of source id + link + title")
    source_id: str
    source_name: str
    title: str
    url: HttpUrl
    summary: str = ""

    #: The date shown on the source page, when one could be parsed. Absent
    #: rather than guessed — a wrong date on an immigration alert is worse than
    #: no date.
    published_at: datetime | None = None

    first_seen_at: datetime = Field(default_factory=utcnow)

    #: Pathway node ids this item was matched to, so the frontend can show a
    #: person only what touches their status.
    matched_nodes: list[str] = Field(default_factory=list)
    tags: list[str] = Field(default_factory=list)

    @staticmethod
    def make_id(source_id: str, url: str, title: str) -> str:
        digest = hashlib.sha256(f"{source_id}|{url}|{title}".encode()).hexdigest()
        return f"news_{digest[:16]}"


class ScrapeReport(BaseModel):
    """What one run of the scraper did — surfaced by `GET /api/news/status`."""

    started_at: datetime
    finished_at: datetime
    items_found: int = 0
    items_new: int = 0
    sources_ok: list[str] = Field(default_factory=list)
    sources_failed: dict[str, str] = Field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.sources_failed


class NewsFeed(BaseModel):
    """The response shape of `GET /api/news/alerts`."""

    items: list[NewsItem]
    total: int
    last_scraped_at: datetime | None = None
    stale: bool = Field(
        default=False,
        description=(
            "True when the newest successful scrape is older than the daily "
            "cadence, so the client can say the feed may be behind instead of "
            "presenting old items as current."
        ),
    )


class SourceInfo(BaseModel):
    """The response shape of `GET /api/news/sources` — shows our work."""

    id: str
    name: str
    url: HttpUrl
    related_nodes: list[str]
    tags: list[str]
    last_scraped_at: datetime | None = None
    last_error: str | None = None
    item_count: int = 0


# ── Case intake ───────────────────────────────────────────────────────────────


class IntakeRequest(BaseModel):
    """`POST /api/case/intake` — free text in."""

    text: str = Field(min_length=1, max_length=4000)

    #: What the person says they are aiming for, when they said it separately
    #: from their situation. Optional: the reasoner will also pick a goal out of
    #: `text` alone.
    goal: str | None = Field(default=None, max_length=1000)


class IntakeFact(BaseModel):
    """One thing the reasoner believes it read out of the person's description.

    A list of label/value pairs rather than a fixed schema: the facts that
    matter differ wildly by family (degree field for F-1, priority date for EB-2,
    entry date for asylum), and inventing a union of every family's fields would
    be a worse contract than showing the person exactly what was understood.
    """

    label: str
    value: str


class IntakeQuestion(BaseModel):
    """A clarifying question — asked, never assumed."""

    id: str
    text: str

    #: boolean | text | choice
    type: str = "text"
    options: list[str] = Field(default_factory=list)


class IntakeResult(BaseModel):
    """`POST /api/case/intake` — a *proposal*, never a commitment.

    Nothing here is written to a case. The frontend shows it, the person
    confirms or corrects it, and only then does it become their status
    (`POST /api/case/confirm`, still spec).
    """

    current_node_id: str | None = None
    current_confidence: str = "low"

    #: Where they said they want to end up. Frequently absent — plenty of people
    #: know their situation and not their destination.
    goal_node_id: str | None = None
    goal_confidence: str = "low"

    #: Other endpoints worth showing alongside the goal, when the described aim
    #: maps to more than one route (e.g. "a green card through work").
    alternative_goal_ids: list[str] = Field(default_factory=list)

    facts: list[IntakeFact] = Field(default_factory=list)
    questions: list[IntakeQuestion] = Field(default_factory=list)
    explanation: str = ""

    #: llm | keywords — which resolver produced this. Surfaced to the user, so
    #: a keyword guess is never mistaken for a reasoned reading.
    source: str = "llm"

    #: Set when the reasoner could not be reached and the keyword fallback ran.
    degraded: bool = False


class IntakeStatus(BaseModel):
    """`GET /api/case/intake/status` — is the reasoner actually configured?

    The frontend asks before offering the free-text path, so it can lead with
    the questionnaire instead of letting someone type out their life story into
    an endpoint that will only keyword-match it.
    """

    llm_available: bool
    model: str | None = None
    node_count: int
    graph_as_of: str = ""
