# Lumos — Your immigration assistant for neurodivergent/struggling brains

Tell it where you stand in your own words, and it holds the rest — your
deadlines, the policy news that actually affects you, and the visa paths still
open to you.

## What Lumos does

- **Understands your visa situation** — plain language in, no forms, no legal
  vocabulary. It shows you the status it resolved before anything is saved.
- **Helps you stay on top of deadlines** — every date your status implies, in
  order, each with the plain reason it exists and the official page it came
  from.
- **Tracks the latest news updates**, and sends you only the relevant ones —
  official policy updates, filtered down to the one question that matters:
  does this change anything for *you*? — and explains them in a way you can
  understand.
- **Helps you explore and understand different visa pathways** and helps you
  prepare ahead of time, including steps to take for changing to other visa
  types and profile building for O-1/EB-1 visas.
- **Data privacy is guaranteed** — see [Privacy](#privacy) below for exactly
  what is and is not stored.

## Why it exists

Immigration runs on hard dates and high stakes, and the people navigating it are
also holding down jobs, degrees, families and everything else. One missed window
can cost years.

Plenty of us are doing that while anxious, stretched thin, or wired in a way that
makes long-range planning genuinely harder — ADHD and autism are simply more
common than the paperwork assumes. That is a design problem, not a character
flaw, and the design has never been on the applicant's side.

So Lumos holds the state for you: it remembers the dates, surfaces only what is
relevant to your situation, and cuts big intimidating processes down to the one
small thing to do next.

## Privacy

**What we do NOT store:**
- No personal documents (passports, I-20s, receipts, visas, etc.)
- No email address
- No name, phone, address, or identifying information
- No uploaded files or attachments
- No payment information

**What we store (minimal):**
- Your Google sign-in ID (anonymous, immutable identifier)
- Your visa situation as you describe it in plain text ("I'm on H-1B", "my OPT expires in June")
- Your goals in plain text ("I want a green card")
- Deadlines derived from your situation (dates only, no documents)
- Which news updates are relevant to you (automatic filtering)

**Data access:**
- Only you can access your own data (verified by Google sign-in)
- No cross-user data leakage
- No personal data in logs or analytics

## Where things are

| Path | What's there |
|---|---|
| [docs/PROJECT_PRD.md](docs/PROJECT_PRD.md) | Product requirements, scope, rollout order, data model |
| [docs/SUBMISSION.md](docs/SUBMISSION.md) | Elevator pitch, project story, demo script |
| [docs/generic_pathways.json](docs/generic_pathways.json) | The pathway graph: 40 statuses, 55 transitions, 12 families |
| [frontend/](frontend/) | Flutter web app — **built**, see [frontend/README.md](frontend/README.md) |
| [frontend/docs/](frontend/docs/) | UI PRD, the Flowmapp design system, HTML mockup |
| [backend/](backend/) | FastAPI service — news scraper **built**, see [backend/README.md](backend/README.md) |
| [backend/docs/API_ENDPOINTS.md](backend/docs/API_ENDPOINTS.md) | Every endpoint the frontend is written against |

Running it locally, including credentials setup: see [docs/RUNNING.md](docs/RUNNING.md).

## Status

**Frontend** (`cd frontend && flutter run -d chrome`) — runs standalone:

- Landing page with the animated pathway journey — hero, "why this exists",
  what-it-does capability grid, privacy panel and closing call to action
- Site nav adapts to sign-in state: signed out gets sign-in/get-started
  actions, signed in gets a "My pathway" link straight to the dashboard plus
  an account chip on wide layouts
- Real Google sign-in (says so plainly when no OAuth client id is configured)
- The full interactive pathway map: 43 statuses, 79 transitions, pan + zoom
- `/intake` — describe your situation in your own words, or answer a short
  questionnaire that runs entirely in the browser; either way you get a proposed
  current status and goal, and nothing is saved until you accept it
- Personal dashboard driven by that case, and a `/news` feed of scraped policy
  updates

**Backend** (`cd backend && uvicorn app.main:app --port 8000`) — news and intake:

- Daily scraper over a curated allow-list of official sources, led by the
  Federal Register API
- `GET /api/news/alerts`, `/sources`, `/status`, `POST /api/news/refresh`
- `POST /api/case/intake` — free text in, a proposed status and goal out,
  reasoned by Claude and constrained to real node ids. Falls back to keyword
  matching (labelled as such) with no `ANTHROPIC_API_KEY` set
- Auth, case confirmation, compliance and chat remain spec only

Lumos supports, and does not replace, a licensed immigration attorney.
