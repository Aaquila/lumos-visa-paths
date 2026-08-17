# Lumos backend

FastAPI service behind Lumos — the immigration assistant for neurodivergent
and struggling brains. Currently implements two slices: the **news slice** —
a daily scraper over a curated allow-list of official immigration sources,
feeding the landing page's promise to track the latest updates and surface
only what's relevant — and **case intake**, which turns a person's
description of their situation into a place on the pathway graph. The rest of
the API surface is specified in [docs/API_ENDPOINTS.md](docs/API_ENDPOINTS.md)
but not yet built.

## Run it

```bash
cd backend
pip install -r requirements.txt
# Using the run script (reads BACKEND_HOST and BACKEND_PORT from .env):
../scripts/run_backend.sh

# Or manually with uvicorn (uses 127.0.0.1:8000 by default):
uvicorn app.main:app --reload --port 8000
```

Then open <http://127.0.0.1:8000/docs> for the generated OpenAPI page.

To change the host or port, edit `BACKEND_HOST` and `BACKEND_PORT` in the root
`.env` file. Or pass them to the script: `./scripts/run_backend.sh --host 0.0.0.0 --port 9000`.

The frontend points at `http://127.0.0.1:8000` by default. To aim it elsewhere:

```bash
cd frontend
flutter run -d chrome --dart-define=API_BASE_URL=https://your-api.onrender.com
```

The frontend works with the backend down — the news panel says so instead of
showing stale or invented data.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/health` | Liveness, plus when the feed was last refreshed |
| `GET` | `/api/news/alerts` | The feed. `?node=temp_worker.h1b`, `?source=`, `?days=`, `?limit=`, `?offset=` |
| `GET` | `/api/news/sources` | The allow-list and each source's last result — including failures |
| `GET` | `/api/news/status` | The last scrape run in full |
| `POST` | `/api/news/refresh` | Scrape now (409 if one is already running) |
| `GET` | `/api/case/intake/status` | Whether a reasoning model is configured, and which |
| `POST` | `/api/case/intake` | Free text in → a *proposed* current status and goal out |

## How intake works

`POST /api/case/intake` takes what somebody writes about their situation and
returns where that puts them on the graph — plus where they said they want to
end up, when they said it. It **proposes only**; nothing is stored, and the
frontend makes the person confirm before it becomes their case.

Two resolvers, in order:

1. **The reasoner** (`claude-opus-5`, via the Anthropic SDK). The response is
   constrained by a JSON schema whose status fields are an *enum of the real
   node ids* from `docs/generic_pathways.json`, so the model cannot return a
   status that is not on the map. `"unknown"` is in that enum on purpose: the
   model is told to leave a field unresolved and ask a clarifying question
   rather than guess, and a confident wrong status is the failure mode that
   matters here.
2. **Keyword matching**, when no `ANTHROPIC_API_KEY` is set or the call fails.
   It only matches statuses people *name* — "I finished my masters and my
   employer is sponsoring me" resolves to nothing, which is the honest answer.
   Every response carries `source` and `degraded` so a keyword guess is never
   presented as a reasoned reading.

The frontend has a third path this service never sees: a fixed questionnaire it
resolves locally, so intake still works with this API switched off entirely.

Also worth knowing:

- **The whole node list is sent, not retrieved.** 43 nodes is smaller than a
  retrieval step would cost, and a complete list is what stops the model
  inventing a status.
- **The system prompt is cached** (it is identical on every request and dwarfs
  the user's text, which comes after the cache breakpoint).
- **Rate limited** — 12 requests per IP per 10 minutes by default. This is the
  one LLM-backed endpoint and it is unauthenticated.
- **A refusal falls back rather than failing.** If safety classifiers decline a
  request, the keyword resolver answers instead of the caller getting a dead end.

## How the scraper works

Two kinds of source, in priority order:

1. **Federal Register API** — the government's own machine-readable feed of
   rules, proposed rules and notices from USCIS, DHS, State and DOL. An official,
   documented, unauthenticated API. This is the primary source: no selectors to
   break, and it is the authoritative record of a policy change rather than a
   summary of one.
2. **Curated HTML pages** — the USCIS newsroom, Study in the States, the Visa
   Bulletin. These carry operational updates that never reach the Federal
   Register (cap-season announcements, processing alerts).

**A known limitation, stated plainly:** several `.gov` sites (uscis.gov,
studyinthestates.dhs.gov, travel.state.gov) sit behind bot protection that
returns `403` to any non-browser client, and they do so from some networks and
not others. On the machine this was developed on, all five HTML sources are
blocked and all four Federal Register sources succeed — the feed is real and
current, but sourced entirely from the API half. The failures are reported
per-source through `/api/news/sources` and shown in the UI rather than hidden,
because a feed that silently loses half its inputs is worse than one that says
so. If you deploy somewhere those sites do answer, the HTML sources start
contributing with no code change.

Behaviour worth knowing:

- **Curated, never crawled.** Only URLs in `app/sources.py` are fetched; links
  found on those pages are stored but never followed.
- **Polite.** One request per source, a delay between sources, a timeout, and
  `robots.txt` is checked before any HTML fetch.
- **An empty result is a failure.** A page that matches no selector is reported
  as broken rather than returning an empty list, because a redesign looks
  exactly like "no news" otherwise.
- **Dates are parsed, never invented.** No date on the page means no date on the
  item.
- **Matching is deliberately narrow.** An item is attached to a pathway node
  either because its source is inherently about that status, or because it
  matches a specific keyword. A false match that moves someone's deadline is
  worse than a missed alert.

## Scheduling

The daily run is an in-process loop (`_daily_loop` in `app/main.py`), so a single
Render web service is enough for the demo. For production, disable it with
`SCRAPE_ON_STARTUP=0` and point a Render Cron Job at `POST /api/news/refresh` —
identical work, but it survives the web process being recycled.

## Environment

All configuration comes from the root `.env` file:

| Variable | Default | Meaning |
|---|---|---|
| `BACKEND_HOST` | `127.0.0.1` | Host to bind to (0.0.0.0 for all interfaces) |
| `BACKEND_PORT` | | Port to listen on |
| `GOOGLE_AUTH_CLIENT_ID` | — | Google OAuth Web client ID (for token verification) |
| `GOOGLE_AUTH_CLIENT_SECRET` | — | Google OAuth secret (reserved for future use) |
| `SCRAPE_ON_STARTUP` | `1` | Scrape at boot when the stored feed is stale |
| `ANTHROPIC_API_KEY` | — | Enables the intake reasoner. Without it, intake falls back to keyword matching and says so |
| `INTAKE_MODEL` | `claude-opus-5` | Model for `POST /api/case/intake` |
| `INTAKE_EFFORT` | `medium` | Reasoning effort — intake is a bounded classification, not open-ended research |
| `INTAKE_RATE_LIMIT` | `12` | Intake requests per IP per 10 minutes |
| `CORS_ORIGINS` | `*` | Comma-separated allowed origins |
| `LOG_LEVEL` | `INFO` | Standard logging level |

## Storage

SQLite at `backend/data/news.sqlite3`, created on first run — the smallest thing
that survives a restart. When the Postgres schema in PROJECT_PRD §7a lands,
`news_alerts` replaces this table and per-user matching moves into SQL; the
shapes in `app/models.py` are already compatible.

## Not built yet

Auth, `POST /api/case/confirm` and the rest of the case-facts endpoints,
compliance deadlines, agent chat and the evidence tracker.
`/api/news/*` needs no authentication because it serves public policy documents
matched to a *status*, not to a person. Per-user alert state (dismissals,
"applied to my tracker") arrives with the user table, and those endpoints will
require a session.
