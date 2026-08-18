"""Wire formats shared by the scraper, the store and the API."""

from __future__ import annotations

import hashlib
from datetime import date, datetime, timezone

from pydantic import BaseModel, Field, HttpUrl


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class DocumentMeta(BaseModel):
    """Structured metadata the Federal Register API gives us for free.

    Kept as its own object rather than folded into `tags` because relevance
    scoring wants to reason over *fields* — "is this a final rule from USCIS
    amending 8 CFR 214 with an effective date next month" — not over a bag of
    words. Every field is optional: HTML sources carry none of this, and an
    absent field must read as "unknown", never as a default.
    """

    #: Rule | Proposed Rule | Notice | Presidential Document
    document_type: str = ""

    #: The Federal Register document number, e.g. "2026-01234".
    document_number: str = ""

    #: The agency's own one-line description of what the document does
    #: ("Final rule; correction", "Notice of proposed rulemaking").
    action: str = ""

    #: Agency slugs, e.g. ["u-s-citizenship-and-immigration-services"].
    agencies: list[str] = Field(default_factory=list)
    docket_ids: list[str] = Field(default_factory=list)

    #: CFR parts touched, e.g. ["8 CFR 214", "8 CFR 274a"]. The strongest
    #: available signal for *which* population a rule reaches.
    cfr_references: list[str] = Field(default_factory=list)

    #: When the rule bites, and when a comment window shuts. These are the two
    #: dates that can actually move somebody's plans.
    effective_on: date | None = None
    comments_close_on: date | None = None


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

    #: Structured publisher metadata when the source is an API. Empty for the
    #: HTML sources, which is exactly why relevance scoring treats it as a
    #: bonus signal rather than a requirement.
    meta: DocumentMeta = Field(default_factory=DocumentMeta)

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


class PathwayOption(BaseModel):
    """One route somebody could take, as an *option* rather than a graph node.

    Everything descriptive here is copied out of the `work_option` block in
    `generic_pathways.json` — the backend orders these, it does not author the
    immigration content. `reason` is the one generated field: it says why this
    option landed in the bucket it did.
    """

    node_id: str
    name: str

    #: nonimmigrant work | immigrant | student-work | dependent | investor |
    #: humanitarian
    category: str = ""

    summary: str = ""
    who_it_fits: str = ""
    eligibility_signals: list[str] = Field(default_factory=list)
    typical_timeline: str = ""
    cost_ballpark: str = ""

    needs_employer_sponsor: bool = True
    allows_self_petition: bool = False

    #: Empty when the route is open to any nationality. Otherwise the
    #: restriction in words — the E-1/E-2 treaty lists are not enumerated here
    #: because they change and the State Department owns them.
    country_restricted: list[str] = Field(default_factory=list)

    risk_notes: list[str] = Field(default_factory=list)
    next_steps: list[str] = Field(default_factory=list)

    #: How this route runs alongside others (working on OPT while an H-1B is
    #: pending, filing a NIW while on H-1B), when that applies.
    parallel_notes: str | None = None

    #: strong_fit | possible_with_changes | long_shot
    bucket: str
    #: 0..1, comparable only within one response.
    fit_score: float
    #: Why it is in that bucket, addressed to the person.
    reason: str

    #: The unanswered questions that would move this option between buckets.
    open_questions: list[str] = Field(default_factory=list)

    source_hint: str = ""


class OptionBucket(BaseModel):
    """A named band of options. Always all three, even when one is empty —
    an empty "strong fit" band is itself the answer."""

    id: str
    label: str
    description: str
    node_ids: list[str] = Field(default_factory=list)


class StrategyNote(BaseModel):
    """Guidance that belongs to no single option (parallel filings, nationality)."""

    id: str
    title: str
    body: str


class PathwayOptionSet(BaseModel):
    """`POST /api/case/options` — the answer to a broad goal.

    A broad goal ("I want to work in the US") is a direction, not a
    destination. Answering it with one node is how a person ends up believing
    H-1B is the only route, so this returns *every* plausible option, bucketed
    by fit, with a reason on each and never truncated.
    """

    #: work_in_us | green_card
    goal: str
    goal_label: str
    goal_description: str = ""

    options: list[PathwayOption] = Field(default_factory=list)
    buckets: list[OptionBucket] = Field(default_factory=list)

    #: Surfaced separately because these are the routes people miss when they
    #: assume an employer must sponsor them — O-1A (agent-petitioned), EB-1A,
    #: EB-2 NIW, E-2, EB-5.
    no_employer_needed: list[str] = Field(default_factory=list)
    self_petition_routes: list[str] = Field(default_factory=list)

    strategy_notes: list[StrategyNote] = Field(default_factory=list)

    #: What the ranking believed about the person, so a wrong reading is
    #: visible and correctable rather than silently driving the order.
    signals_read: dict[str, bool] = Field(default_factory=dict)

    #: The questions that would most change this ranking, deduplicated across
    #: options.
    questions: list[IntakeQuestion] = Field(default_factory=list)

    graph_as_of: str = ""
    disclaimer: str = ""


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

    #: Present when the person described a *direction* rather than a
    #: destination — "I want to work in the US". `goal_node_id` alone would
    #: collapse that to a single status; this carries the whole ranked option
    #: set instead. Null when the goal was specific (or absent), in which case
    #: nothing about the older shape changes.
    options: PathwayOptionSet | None = None

    #: Always populated. Immigration information is never advice.
    disclaimer: str = ""


# ── News relevance ────────────────────────────────────────────────────────────


class SituationInput(BaseModel):
    """The caller's own situation, sent with a scoring request.

    **This is never stored.** It arrives on the request, it is scored, and it
    goes out of scope with the response — see the no-persistence note on
    `POST /api/news/relevant` in `app/main.py`. Nothing in `app/store.py`
    accepts this type, and nothing may be added that does.

    Every field is optional because the client has partial answers far more
    often than complete ones: somebody who has only tapped "F-1 student" in
    onboarding still deserves a sorted feed.
    """

    #: Their status in their own words ("my OPT started in June").
    status_text: str = Field(default="", max_length=4000)

    #: What they want next, in their own words.
    goal_text: str = Field(default="", max_length=2000)

    #: Pathway node ids already resolved by intake, when the client has them.
    current_node_id: str | None = Field(default=None, max_length=100)
    goal_node_id: str | None = Field(default=None, max_length=100)

    #: Any further nodes the client considers the person's — the option set's
    #: strong-fit routes, typically.
    node_ids: list[str] = Field(default_factory=list, max_length=40)

    #: When their status next changes or expires, if they said. Month optional:
    #: "some time in 2027" is a real answer and is not rounded into precision.
    change_year: int | None = Field(default=None, ge=2000, le=2100)
    change_month: int | None = Field(default=None, ge=1, le=12)

    #: Country of citizenship, when volunteered. Used only to match
    #: country-specific items (TPS designations, per-country backlogs).
    country: str | None = Field(default=None, max_length=80)

    @property
    def is_empty(self) -> bool:
        return not any(
            [
                self.status_text.strip(),
                self.goal_text.strip(),
                self.current_node_id,
                self.goal_node_id,
                self.node_ids,
            ]
        )


class RelevanceSignal(BaseModel):
    """One concrete, nameable thing that made an item score.

    The whole point of this object is that no ranking is unexplained: every
    verdict is the sum of these, and each one says what it saw and where.
    """

    #: node | form | category | agency | fee | cap | processing_time |
    #: policy_manual | country | document_type | deadline | comment_window
    kind: str

    #: The signal in words, e.g. "Form I-765" or "H-1B".
    label: str

    #: Where it was seen: title | summary | metadata | matched_nodes | cfr
    found_in: str

    #: How much it moved the score. Positive only — nothing is penalised
    #: silently.
    weight: float


class RelevanceVerdict(BaseModel):
    """How one news item relates to one person's situation.

    Deliberately phrased as *looks relevant*, never as *affects*. This is a
    keyword-and-metadata match over a public document; it is not a legal
    determination and must never read like one.
    """

    #: affects_you | worth_knowing | background
    level: str

    #: 0..1. Comparable only within one response.
    confidence: float

    #: The concrete signal that produced this level. Never empty.
    reason: str

    #: 2–3 plain sentences, second person, about this person's situation.
    what_this_means: str

    #: Everything that matched, so the ranking can be audited.
    signals: list[RelevanceSignal] = Field(default_factory=list)

    #: Which of the person's pathway nodes this item touches.
    touches_nodes: list[str] = Field(default_factory=list)

    #: Dates on this item that could move the person's own timeline. Words, not
    #: a computed deadline — we do not manufacture deadlines.
    touches_deadlines: list[str] = Field(default_factory=list)

    #: deterministic | deterministic+llm — which path wrote `what_this_means`.
    #: The level, confidence and reason are always deterministic.
    explained_by: str = "deterministic"


class RelevantNewsItem(BaseModel):
    """A news item with its verdict attached. The item itself is unchanged."""

    item: NewsItem
    relevance: RelevanceVerdict


class PersonalisedNewsFeed(BaseModel):
    """`POST /api/news/relevant` — the feed, sorted by what touches you.

    Same items as `GET /api/news/alerts`; different order, plus a verdict on
    each. The situation used to produce it is not stored anywhere.
    """

    items: list[RelevantNewsItem] = Field(default_factory=list)
    total: int = 0

    #: level → count, so the client can group without re-counting.
    counts: dict[str, int] = Field(default_factory=dict)

    last_scraped_at: datetime | None = None
    stale: bool = False

    #: False when the caller sent nothing usable — the client should then show
    #: the plain chronological list and ask for their situation.
    personalised: bool = False

    #: True when an LLM refined any explanation. False is the normal case and
    #: is not a degraded one: the deterministic path is the product.
    llm_used: bool = False

    #: Restates that this is information, not advice. Always populated.
    disclaimer: str = ""


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


# ── Personalized news endpoints ───────────────────────────────────────────────


class UserNewsArticle(BaseModel):
    """One article in a user's personalized news feed."""

    article_id: str
    title: str
    link: str
    summary: str
    relevance_reason: str = ""
    marked_read_at: datetime | None = None
    is_unread: bool = True

    #: `relevance.AFFECTS_YOU` or `WORTH_KNOWING` — never `BACKGROUND`, since
    #: those never get a `UserNews` row. Lets the client filter to items that
    #: name the reader's own status/form/country, not just anything adjacent.
    relevance_level: str = "worth_knowing"

    #: Claude-written one-line "what this means for you" headline — or the
    #: literal `summarizer.NOT_RELEVANT_HEADLINE` when the document doesn't
    #: touch this reader's situation. `None` when not yet generated (no API
    #: key, generation failed, or the article predates this feature) — the
    #: client falls back to `title`.
    personalized_headline: str | None = None

    #: The plain-language explanation behind `personalized_headline`. `None`
    #: under the same conditions — the client falls back to `summary`.
    personalized_summary: str | None = None


class UnreadNewsFeedResponse(BaseModel):
    """Response for GET /api/user/news/unread."""

    articles: list[UserNewsArticle]
    count: int


class UnreadCountResponse(BaseModel):
    """Response for GET /api/user/news/unread/count."""

    count: int


class AllNewsFeedResponse(BaseModel):
    """Response for GET /api/user/news/all."""

    articles: list[UserNewsArticle]
    total: int
    limit: int
    offset: int


class MarkReadResponse(BaseModel):
    """Response for POST /api/user/news/:article_id/read."""

    status: str
    marked_read_at: datetime | None


class SaveSituationRequest(BaseModel):
    """`POST /api/user/situation` — the one place a situation is persisted.

    Contrast with `SituationInput`: that one is scored in memory and dropped
    with the response. This one is written to `UserVisaSituation` and read
    back by `personalize_articles` on every scrape, because matching news to
    a person's situation after the fact requires having it later. Same two
    free-text fields, on purpose — this is what a person confirmed as their
    status and goal, not a new shape to reconcile.
    """

    status_text: str = Field(min_length=1, max_length=2000)
    goal_text: str = Field(default="", max_length=2000)


class SavedSituation(BaseModel):
    """The authenticated user's currently recorded situation, or absence of one."""

    status_text: str = ""
    goal_text: str = ""
    updated_at: datetime | None = None

    #: False when the user has never saved a situation — distinguishes "no
    #: situation recorded" from "recorded empty text".
    has_situation: bool = False


class SaveSituationResponse(BaseModel):
    """Response for POST /api/user/situation."""

    status: str
    updated_at: datetime


# ── Voice assistant ──────────────────────────────────────────────────────────


class VoiceTranscript(BaseModel):
    """`POST /api/voice/transcribe` — the response shape.

    The uploaded audio itself is never written anywhere; it is handed to
    ElevenLabs for transcription and dropped once this comes back.
    """

    transcript: str


class VoiceAssistantTurn(BaseModel):
    """One earlier turn of the conversation, kept in the browser only.

    The client resends the last few turns with each request so the assistant
    has context; nothing here is persisted server-side between requests.
    """

    #: user | assistant
    role: str
    text: str = Field(max_length=2000)


class VoiceDeadlineContext(BaseModel):
    """One deadline as the client currently sees it — enough for the
    assistant to refer to it and to target it with an action, no more.

    Mirrors the frontend's `Deadline` model loosely; only the fields the
    assistant actually needs to reason about or act on.
    """

    id: str
    title: str
    description: str = ""
    due_date: date | None = None
    is_approximate: bool = False
    severity: str = "important"
    source: str = "user-added"


class VoiceCaseContext(BaseModel):
    """The person's current status/goal, in their own words, as the client
    holds it locally. Never stored server-side — same rule as
    `SituationInput` above."""

    current_status_text: str = Field(default="", max_length=2000)
    goal_text: str = Field(default="", max_length=1000)


class VoiceAssistantRequest(BaseModel):
    """`POST /api/voice/assistant` — a transcript plus just enough context.

    Everything here is per-request only. The case and deadline snapshots are
    exactly what the caller already holds client-side; the backend does not
    look any of it up and does not remember it after the response is sent.
    """

    transcript: str = Field(min_length=1, max_length=2000)
    history: list[VoiceAssistantTurn] = Field(default_factory=list, max_length=12)
    case: VoiceCaseContext = Field(default_factory=VoiceCaseContext)
    deadlines: list[VoiceDeadlineContext] = Field(default_factory=list, max_length=100)


class VoiceAssistantAction(BaseModel):
    """One proposed change to the deadline list.

    A *proposal* only — like `IntakeResult`, nothing here is applied on the
    backend. The client is the one holding `DeadlineService`, so it executes
    each action itself via the same methods a person's own tap would call.
    """

    #: add_deadline | dismiss_deadline | restore_deadline | snooze_deadline
    kind: str

    #: Present for dismiss/restore/snooze — the id of the existing deadline.
    target_id: str | None = None

    #: Present for add_deadline.
    title: str | None = None
    description: str | None = None
    next_action: str | None = None
    due_date: date | None = None
    is_approximate: bool = False

    #: Present for snooze_deadline.
    until: date | None = None


class VoiceAssistantResponse(BaseModel):
    """`POST /api/voice/assistant` — the reply and what it proposes to change."""

    reply_text: str
    actions: list[VoiceAssistantAction] = Field(default_factory=list)

    #: Set when the reasoner could not be reached and a canned reply was used
    #: instead — mirrors `IntakeResult.degraded`.
    degraded: bool = False


class VoiceSpeakRequest(BaseModel):
    """`POST /api/voice/speak` — text in, spoken audio out."""

    text: str = Field(min_length=1, max_length=600)


class GoogleSessionRequest(BaseModel):
    """`POST /api/auth/session` — a Google ID token, exchanged once."""

    id_token: str = Field(min_length=1)


class SessionTokenResponse(BaseModel):
    """`POST /api/auth/session` — the Lumos session token that replaces it.

    Google ID tokens live about an hour and the browser SDK does not renew
    them, so the client cannot keep presenting one for the length of a signed-in
    visit. This is the longer-lived token it presents instead; `expires_at` is
    when the client must sign in again.
    """

    access_token: str
    expires_at: datetime
    token_type: str = "Bearer"
