"""Claude-generated plain-language news summaries, personalized per user.

The government text scraped into `NewsArticle.summary` (see `scraper.py`) is
verbatim agency prose — Federal Register abstracts, regulatory-agenda text —
written for people who already know the jargon. This module rewrites that
text in plain language and frames it against one user's own stated situation,
using the same lazy-client / graceful-degrade pattern as
`relevance.RelevanceScorer`: no API key means the feature is silently off,
never a crash, and the raw `summary` field remains available as a fallback
wherever a personalized one hasn't been generated.
"""

from __future__ import annotations

import logging
import os

from .models import NewsItem, SituationInput

log = logging.getLogger("lumos.summarizer")

MODEL = os.getenv("SUMMARY_MODEL", "claude-opus-5")

#: Restating an abstract in plain words is a rewrite, not a reasoning task.
EFFORT = os.getenv("SUMMARY_EFFORT", "low")

_SYSTEM = """\
You rewrite one government notice as a short, plain-language explanation for \
Lumos, a US immigration tracker, personalized to one reader's own situation.

You are given a government document (title and abstract) and a reader's \
situation in their own words. Your job is to explain, in plain English, what \
the document is and why it might matter to someone in that situation.

Rules, all of them hard:
- 2 to 4 sentences. Second person ("you"). No jargon a person would have to \
look up — spell out or briefly define any regulatory term you must use (e.g. \
"interim final rule" -> "a rule that takes effect immediately").
- Ground every sentence in the title and abstract you were given. Never add a \
fee amount, a date, a deadline, a processing time, or an eligibility rule \
that is not stated in the material given to you.
- Connect it to the reader's situation only when the document's own content \
supports the connection. If the document does not clearly relate to their \
situation, say plainly that it looks like general/background news and explain \
what it covers instead of forcing a connection.
- Never claim the document changes the reader's status, approves or denies \
anything, or requires the reader to do something — describe what it is, not \
what to do about it.
- No legal advice, no predictions about outcomes.
Return only the explanation, no preamble, no heading.
"""


class PersonalizedSummarizer:
    """Generates a plain-language, situation-aware summary for one article.

    Mirrors `relevance.RelevanceScorer`'s optional-LLM shape: no API key or
    any failure (network, rate limit, refusal) means `summarize()` returns
    `None` rather than raising, so callers always have the deterministic
    `NewsArticle.summary` to fall back to.
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
    ) -> str | None:
        """Return a personalized plain-language explanation, or `None`.

        `None` covers every failure mode (no client, refusal, rate limit,
        malformed response) uniformly — the caller's fallback is always the
        raw scraped `summary`, so there is nothing more specific to report.
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
            "Write the explanation."
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
                output_config={"effort": EFFORT},
                messages=[{"role": "user", "content": prompt}],
            )
        except Exception:  # noqa: BLE001
            # Deliberately not logging the situation or the exception body:
            # the request carries the person's own words.
            log.warning("personalized summary generation failed")
            return None

        if response.stop_reason == "refusal":
            return None

        text = next((b.text for b in response.content if b.type == "text"), "")
        text = " ".join(text.split())
        # A runaway or empty response is worse than no personalized summary.
        return text if 0 < len(text) <= 1200 else None


__all__ = ["PersonalizedSummarizer"]
