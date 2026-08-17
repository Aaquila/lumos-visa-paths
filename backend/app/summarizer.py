"""Claude-generated plain-language news explanations, personalized per user.

The government text scraped into `NewsArticle.summary` (see `scraper.py`) is
verbatim agency prose — Federal Register abstracts, regulatory-agenda text —
written for people who already know the jargon. This module produces two
things a reader actually wants instead: a one-line, personalized "what this
means for you" headline, and a short plain-language explanation behind it —
or, when the document genuinely doesn't touch their situation, an honest "not
relevant to you" instead of a forced connection.

Uses the same lazy-client / graceful-degrade pattern as
`relevance.RelevanceScorer`: no API key means the feature is silently off,
never a crash, and the raw `NewsArticle.summary`/title remain available as
the fallback wherever a personalized insight hasn't been generated.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass

from .models import NewsItem, SituationInput

log = logging.getLogger("lumos.summarizer")

MODEL = os.getenv("SUMMARY_MODEL", "claude-opus-5")

#: Restating an abstract in plain words is a rewrite, not a reasoning task.
EFFORT = os.getenv("SUMMARY_EFFORT", "low")

#: The phrase used whenever the document doesn't say anything that applies to
#: the reader's own status/goal. Matched by the frontend to style it as a
#: neutral "skip" rather than a personalized insight.
NOT_RELEVANT_HEADLINE = "Not directly relevant to your situation"

_SYSTEM = """\
You read one government notice for Lumos, a US immigration tracker, and tell \
one reader — in their own situation, in their own words — whether it actually \
affects them and, if so, how. You are not summarizing the document for its \
own sake; you are answering the reader's real question: "does this change \
anything for me?"

You are given a government document (title and abstract) and a reader's \
situation in their own words. Return two things:

1. `headline` — ONE short sentence (under 14 words), plain language, stating \
the effect on THIS reader specifically. Not a restatement of the document's \
title. Examples of the right shape: "This doesn't change anything for your \
H-1B renewal", "Your OPT work permit process just got a new online option", \
"This is about ship crew visas, not your situation". If the document's own \
content does not clearly connect to the reader's stated status or goal, set \
`headline` to exactly: "Not directly relevant to your situation" — do not \
invent a connection to make the headline feel more useful than it is.

2. `summary` — 2 to 4 short sentences expanding on the headline. When \
relevant, cover, in this order: (a) why it's relevant — what in the document \
connects to their stated status or goal; (b) how it affects them — what is \
different for someone in their situation because of this; (c) what changes — \
the concrete thing that changed (a process, an option, a requirement, a form) \
stated only from what's in the abstract, never a date or number that isn't \
there. Not three separate labeled points — one flowing explanation that hits \
all three. When not relevant, skip (a)-(c) and just say plainly what the \
document actually covers instead (one sentence is enough) so the reader isn't \
left wondering why it showed up.

Write for a smart friend, not a regulator. Ordinary immigration words are \
fine and expected — visa, green card, USCIS, H-1B, work permit, deadline, \
application, sponsor. What you must strip out of BOTH fields is *regulatory \
and legal-drafting* jargon: words that describe the rulemaking process itself \
rather than the visa system. Never use, even once: "nonimmigrant \
classification", "interim final rule", "notice of proposed rulemaking", \
"docket", "CFR" or "C.F.R.", "promulgate(d)", "rulemaking", "the Secretary", \
"regulatory agenda", "comment period" (say "the public can respond until \
[date]" instead), "effective date" (say "starts on [date]" instead), or any \
bare citation like "8 CFR 214.2". Translate any such term from the source \
text into its plain everyday equivalent instead of repeating it — e.g. \
"aliens" -> "immigrants" or "visa holders" depending on context; \
"nonimmigrant" -> "temporary visa"; "adjudicate" -> "decide"; "petitioner" -> \
"the person or company applying".

Rules, all of them hard:
- Second person ("you") in both fields.
- Ground every sentence in the title and abstract you were given. Never add a \
fee amount, a date, a deadline, a processing time, or an eligibility rule \
that is not stated in the material given to you.
- Never claim the document changes the reader's status, approves or denies \
anything, or requires the reader to do something — describe what it is, not \
what to do about it.
- No legal advice, no predictions about outcomes.
"""

_SCHEMA = {
    "type": "object",
    "properties": {
        "headline": {
            "type": "string",
            "description": (
                "One short sentence (under 14 words) stating the effect on "
                "this specific reader, or exactly 'Not directly relevant to "
                "your situation' when it doesn't apply to them."
            ),
        },
        "summary": {
            "type": "string",
            "description": (
                "2 to 4 short plain-language sentences expanding on the "
                "headline: why it's relevant to this reader, how it affects "
                "them, and what concretely changes — or, when not relevant, "
                "one sentence on what the document actually covers."
            ),
        },
    },
    "required": ["headline", "summary"],
    "additionalProperties": False,
}


@dataclass(frozen=True)
class PersonalizedInsight:
    """One reader's personalized read on one article."""

    headline: str
    summary: str

    @property
    def relevant(self) -> bool:
        return self.headline.strip().lower() != NOT_RELEVANT_HEADLINE.lower()


class PersonalizedSummarizer:
    """Generates a personalized headline + explanation for one article.

    Mirrors `relevance.RelevanceScorer`'s optional-LLM shape: no API key or
    any failure (network, rate limit, refusal, malformed output) means
    `summarize()` returns `None` rather than raising, so callers always have
    the article's own title/summary to fall back to.
    """

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
            log.warning("personalized summarizer unavailable (%s)", self._client_error)

    @property
    def available(self) -> bool:
        return self._client is not None

    async def summarize(
        self, item: NewsItem, situation: SituationInput
    ) -> PersonalizedInsight | None:
        """Return a personalized headline + explanation, or `None`.

        `None` covers every failure mode (no client, refusal, rate limit,
        malformed response) uniformly — the caller's fallback is always the
        article's own title and raw summary, so there is nothing more
        specific to report.
        """
        if self._client is None:
            return None

        prompt = (
            f"Document title: {item.title}\n"
            f"Publisher: {item.source_name}\n"
            f"Document type: {item.meta.document_type or 'unknown'}\n"
            f"Abstract: {item.summary or '(none given)'}\n\n"
            f"Reader's current status: {situation.status_text or '(not given)'}\n"
            f"Reader's goal: {situation.goal_text or '(not given)'}\n\n"
            "Return the headline and summary."
        )

        try:
            response = await self._client.messages.create(
                model=MODEL,
                max_tokens=800,
                system=[
                    {
                        "type": "text",
                        "text": _SYSTEM,
                        # Identical on every call and much larger than the payload.
                        "cache_control": {"type": "ephemeral"},
                    }
                ],
                output_config={
                    "effort": EFFORT,
                    "format": {"type": "json_schema", "schema": _SCHEMA},
                },
                messages=[{"role": "user", "content": prompt}],
            )
        except Exception:  # noqa: BLE001
            # Deliberately not logging the situation or the exception body:
            # the request carries the person's own words.
            log.warning("personalized summary generation failed")
            return None

        if response.stop_reason == "refusal":
            return None

        raw = next((b.text for b in response.content if b.type == "text"), "")
        try:
            parsed = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            return None

        headline = " ".join(str(parsed.get("headline", "")).split())
        summary = " ".join(str(parsed.get("summary", "")).split())
        # A missing field or a runaway response is worse than no insight.
        if not headline or not (0 < len(summary) <= 1200) or len(headline) > 200:
            return None
        return PersonalizedInsight(headline=headline, summary=summary)


__all__ = ["PersonalizedSummarizer", "PersonalizedInsight", "NOT_RELEVANT_HEADLINE"]
