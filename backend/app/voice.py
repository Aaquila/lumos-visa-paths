"""Voice assistant — speech in, a spoken reply out, plus proposed changes to
the person's deadline list.

Three pieces, deliberately kept separate so any one of them can fail without
taking the others down:

1. **ElevenLabs speech-to-text** (`ElevenLabsClient.transcribe`) turns a
   recorded clip into text.
2. **The reasoner** (`VoiceAssistant`, `claude-opus-5`), the same
   lazy-client/graceful-degrade shape as `IntakeResolver` in `intake.py`,
   turns that text — plus the person's case and deadline list, sent fresh on
   every request — into a short spoken reply and a list of *proposed*
   deadline-list changes.
3. **ElevenLabs text-to-speech** (`ElevenLabsClient.synthesize`) turns the
   reply back into audio.

Nothing here writes anything. The proposed actions are exactly that —
proposals — and are applied, if at all, by the client calling its own
`DeadlineService` methods; this module never touches a database and the case
and deadline snapshots it is given go out of scope with the response, the
same rule `SituationInput` documents in `models.py`.
"""

from __future__ import annotations

import logging
import os
from datetime import date

import httpx

from .models import (
    VoiceAssistantAction,
    VoiceAssistantRequest,
    VoiceAssistantResponse,
)

log = logging.getLogger("lumos.voice")

MODEL = os.getenv("VOICE_MODEL", "claude-opus-5")

#: A voice reply is a few spoken sentences, not a document — kept modest so
#: replies stay short enough to actually speak aloud.
EFFORT = os.getenv("VOICE_EFFORT", "low")
MAX_TOKENS = 2000

ELEVENLABS_STT_URL = "https://api.elevenlabs.io/v1/speech-to-text"
ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"

#: ElevenLabs' current general-purpose speech-to-text model.
ELEVENLABS_STT_MODEL = "scribe_v1"

_CANNED_UNAVAILABLE_REPLY = (
    "I can't reach the assistant right now. You can still add or edit "
    "deadlines by typing, on the Deadlines page."
)


class ElevenLabsError(Exception):
    """Raised when ElevenLabs is unreachable, misconfigured, or refuses."""


class ElevenLabsClient:
    """Thin wrapper over the two ElevenLabs endpoints this app uses.

    No official SDK dependency — two REST calls over `httpx`, which is
    already a dependency for the scraper. Optional at runtime exactly like
    `IntakeResolver`: with no `ELEVENLABS_API_KEY`, `available` is false and
    callers are expected to check it and answer 503 rather than call in.
    """

    def __init__(self) -> None:
        self._api_key = os.getenv("ELEVENLABS_API_KEY", "").strip()
        self._voice_id = os.getenv("ELEVENLABS_VOICE_ID", "").strip()

    @property
    def available(self) -> bool:
        return bool(self._api_key and self._voice_id)

    async def transcribe(self, audio_bytes: bytes, content_type: str) -> str:
        """One recorded clip -> its text. Raises `ElevenLabsError` on failure."""
        if not self._api_key:
            raise ElevenLabsError("ELEVENLABS_API_KEY is not set")

        files = {"file": ("audio", audio_bytes, content_type or "audio/webm")}
        data = {"model_id": ELEVENLABS_STT_MODEL}
        headers = {"xi-api-key": self._api_key}

        try:
            async with httpx.AsyncClient(timeout=30) as client:
                response = await client.post(
                    ELEVENLABS_STT_URL, headers=headers, data=data, files=files
                )
        except httpx.HTTPError as e:
            raise ElevenLabsError(f"speech-to-text request failed: {e}") from e

        if response.status_code != 200:
            raise ElevenLabsError(
                f"speech-to-text returned {response.status_code}: {response.text[:200]}"
            )

        body = response.json()
        text = body.get("text", "")
        if not isinstance(text, str) or not text.strip():
            raise ElevenLabsError("speech-to-text returned no text")
        return text.strip()

    async def synthesize(self, text: str) -> bytes:
        """Reply text -> spoken audio (MP3). Raises `ElevenLabsError` on failure."""
        if not self._api_key or not self._voice_id:
            raise ElevenLabsError("ElevenLabs voice is not configured")

        url = ELEVENLABS_TTS_URL.format(voice_id=self._voice_id)
        headers = {
            "xi-api-key": self._api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        }
        payload = {
            "text": text,
            "model_id": "eleven_multilingual_v2",
        }

        try:
            async with httpx.AsyncClient(timeout=30) as client:
                response = await client.post(url, headers=headers, json=payload)
        except httpx.HTTPError as e:
            raise ElevenLabsError(f"text-to-speech request failed: {e}") from e

        if response.status_code != 200:
            raise ElevenLabsError(
                f"text-to-speech returned {response.status_code}: {response.text[:200]}"
            )
        return response.content


# ── Reasoner ──────────────────────────────────────────────────────────────────

_SYSTEM = """\
You are the voice assistant for Lumos, a US immigration pathway and deadline \
tracker. A person is talking to you out loud; your reply is spoken back to \
them, so keep it to one or two short, plain sentences — no lists, no legal \
advice, no invented dates or predictions about outcomes.

You are given the person's current status and goal in their own words, and \
their current deadline list, exactly as their device holds it right now. You \
do not remember anything between requests and nothing you see is stored.

You can propose changes to their deadline list using the tools provided. Only \
propose a change the person actually asked for — never add, dismiss, restore \
or snooze something they did not clearly request. When a request is \
ambiguous (which deadline they mean, what date), ask a short clarifying \
question in your reply instead of guessing.

If they are just asking a question ("what's my next deadline", "what does \
OPT mean"), answer briefly from the deadline list and case info you were \
given, and propose no actions.
"""

_TOOLS = [
    {
        "name": "add_deadline",
        "description": "Add a new item to the person's deadline list.",
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Short title, in plain words."},
                "description": {"type": "string"},
                "next_action": {"type": "string", "description": "One concrete next step."},
                "due_date": {
                    "type": "string",
                    "description": "ISO date (YYYY-MM-DD), only if the person gave one.",
                },
                "is_approximate": {
                    "type": "boolean",
                    "description": "True when only a month/year was given, not a day.",
                },
            },
            "required": ["title"],
            "additionalProperties": False,
        },
    },
    {
        "name": "dismiss_deadline",
        "description": "Hide a deadline the person no longer wants to see (reversible).",
        "input_schema": {
            "type": "object",
            "properties": {
                "target_id": {"type": "string", "description": "The deadline's id, from the list given to you."}
            },
            "required": ["target_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "restore_deadline",
        "description": "Un-hide a previously dismissed or snoozed deadline.",
        "input_schema": {
            "type": "object",
            "properties": {
                "target_id": {"type": "string", "description": "The deadline's id."}
            },
            "required": ["target_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "snooze_deadline",
        "description": "Hide a deadline until a given date, without dismissing it outright.",
        "input_schema": {
            "type": "object",
            "properties": {
                "target_id": {"type": "string", "description": "The deadline's id."},
                "until": {"type": "string", "description": "ISO date (YYYY-MM-DD) to hide it until."},
            },
            "required": ["target_id", "until"],
            "additionalProperties": False,
        },
    },
]


class VoiceAssistant:
    """Holds the Anthropic client, lazily, like `IntakeResolver`."""

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
            log.warning("voice assistant unavailable (%s)", self._client_error)

    @property
    def llm_available(self) -> bool:
        return self._client is not None

    async def respond(self, request: VoiceAssistantRequest) -> VoiceAssistantResponse:
        if self._client is None:
            return VoiceAssistantResponse(
                reply_text=_CANNED_UNAVAILABLE_REPLY, actions=[], degraded=True
            )

        try:
            return await self._respond_with_model(request)
        except Exception:  # noqa: BLE001
            # A person mid-conversation gets a plain "try again" rather than a
            # 500 or a dropped connection.
            log.exception("voice assistant failed; degrading")
            return VoiceAssistantResponse(
                reply_text=_CANNED_UNAVAILABLE_REPLY, actions=[], degraded=True
            )

    async def _respond_with_model(
        self, request: VoiceAssistantRequest
    ) -> VoiceAssistantResponse:
        assert self._client is not None

        context_lines = [
            f"Current status (in their words): {request.case.current_status_text or 'not given'}",
            f"Goal (in their words): {request.case.goal_text or 'not given'}",
            "Current deadlines:",
        ]
        if request.deadlines:
            for d in request.deadlines:
                due = f"{d.due_date} (approximate)" if d.is_approximate and d.due_date else str(d.due_date or "no date")
                context_lines.append(f"- id={d.id} | {d.title} | due {due} | severity {d.severity}")
        else:
            context_lines.append("- (none)")

        messages: list[dict] = [
            {"role": "user", "content": "\n".join(context_lines)},
            {"role": "assistant", "content": "Understood, I have the current list."},
        ]
        for turn in request.history:
            role = "assistant" if turn.role == "assistant" else "user"
            messages.append({"role": role, "content": turn.text})
        messages.append({"role": "user", "content": request.transcript})

        response = await self._client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=[{"type": "text", "text": _SYSTEM, "cache_control": {"type": "ephemeral"}}],
            tools=_TOOLS,
            output_config={"effort": EFFORT},
            messages=messages,
        )

        if response.stop_reason == "refusal":
            log.warning("voice assistant refused by safety classifiers")
            return VoiceAssistantResponse(
                reply_text=_CANNED_UNAVAILABLE_REPLY, actions=[], degraded=True
            )

        reply_text = "".join(
            block.text for block in response.content if block.type == "text"
        ).strip()
        actions = [
            action
            for block in response.content
            if block.type == "tool_use"
            for action in [self._to_action(block.name, block.input)]
            if action is not None
        ]

        if not reply_text:
            reply_text = "Done." if actions else "I didn't catch anything to act on — could you say that again?"

        return VoiceAssistantResponse(reply_text=reply_text, actions=actions, degraded=False)

    @staticmethod
    def _to_action(name: str, raw_input: dict) -> VoiceAssistantAction | None:
        if name == "add_deadline":
            title = str(raw_input.get("title", "")).strip()
            if not title:
                return None
            return VoiceAssistantAction(
                kind="add_deadline",
                title=title,
                description=str(raw_input.get("description", "")).strip(),
                next_action=str(raw_input.get("next_action", "")).strip(),
                due_date=_parse_date(raw_input.get("due_date")),
                is_approximate=bool(raw_input.get("is_approximate", False)),
            )
        if name in ("dismiss_deadline", "restore_deadline"):
            target_id = str(raw_input.get("target_id", "")).strip()
            if not target_id:
                return None
            return VoiceAssistantAction(kind=name, target_id=target_id)
        if name == "snooze_deadline":
            target_id = str(raw_input.get("target_id", "")).strip()
            until = _parse_date(raw_input.get("until"))
            if not target_id or until is None:
                return None
            return VoiceAssistantAction(kind=name, target_id=target_id, until=until)
        log.warning("voice assistant proposed unknown tool %r", name)
        return None


def _parse_date(raw: object) -> date | None:
    if not isinstance(raw, str) or not raw.strip():
        return None
    try:
        return date.fromisoformat(raw.strip())
    except ValueError:
        return None
