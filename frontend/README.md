# Lumos — Flutter frontend

The web frontend for Lumos — an immigration assistant for neurodivergent and
struggling brains (see `docs/PROJECT_PRD.md`). Flutter, web target first,
Windows desktop configured for local dev builds.

## Run it

```bash
cd frontend
flutter pub get
flutter run -d chrome          # dev
flutter build web              # deployable bundle in build/web
```

The app runs with nothing else on: the pathway graph is a bundled copy of
`docs/generic_pathways.json`, and the news panel says the service is unreachable
rather than inventing data. Two optional integrations:

```bash
# Real Google sign-in. Without this, the sign-in screen says so and offers a
# clearly-labelled demo session instead of pretending.
flutter run -d chrome --web-hostname localhost --web-port 7357 \
  --dart-define=GOOGLE_CLIENT_ID=<id>.apps.googleusercontent.com

# Live policy news (see backend/README.md to start the API)
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

`7357` matters for Google: the port must match an **Authorized JavaScript
origin** on the OAuth client, and `flutter run` otherwise picks a random one.

## Routes

| Path | Screen | Auth |
|---|---|---|
| `/` | Landing page — where a first-time visitor arrives | public |
| `/signin` | Google sign-in (behind "Get started") | public |
| `/visa-pathways` | The full interactive pathway graph | public |
| `/visa-pathways?node=<id>` | Same map, opened on a specific status | public |
| `/news` | Scraped policy updates, `?node=<id>` to filter | public |
| `/intake` | Place yourself on the map: describe it, or answer questions (`?mode=questions`) | guarded, redirects to `/signin` |
| `/dashboard` | Personal page — status, goal, deadlines, route strip | guarded, redirects to `/signin` |

## Landing page

`lib/screens/landing/landing_page.dart` is a single scrolling page, built from
composable sections so each one can be worked on in isolation:

- **Hero** — the animated traveller-and-luggage pathway journey
  (`lib/widgets/hero_journey.dart`) plus the primary "Get started" CTA
- **Why this exists** — the case for a slower, kinder immigration tool
- **What it does** — a capability grid mirroring the four pillars in the root
  README: understands your situation, keeps you ahead of deadlines, tracks and
  translates news, maps the paths ahead
- **Privacy** — the same store/do-not-store list as the root
  [README's Privacy section](../README.md#privacy), shown before sign-in ever
  comes up
- **Closing CTA** — one sketched-tail call to action (`lib/widgets/wavy_cta.dart`)

The site nav (`lib/widgets/site_nav.dart`) reads sign-in state on every route:
signed out, it shows sign-in and get-started actions; signed in, it adds a
"My pathway" link straight to `/dashboard` and, on wide layouts, an account
chip next to it instead of a duplicate button.

## Intake

`/intake` is how a person becomes a position on the map, and it offers two ways
in rather than one:

- **Describe it in your own words** posts the text to `POST /api/case/intake`,
  where a reasoning agent places it on the graph and says what it still needs to
  know. Offered first only when the backend reports a configured model
  (`GET /api/case/intake/status`) — otherwise it would quietly downgrade to
  keyword matching, so the page says that instead.
- **Answer a few questions** walks a short branching questionnaire
  (`lib/models/intake_questionnaire.dart`) entirely in the client. No service, no
  key, nothing leaves the device. It is always available, and it is what the page
  leads with when the agent is not.

Both produce the same `CaseProfile`, and both **propose** — nothing is stored
until the person presses "Use this as my pathway". Every result carries how it
was arrived at (reasoned, keyword-matched, or answered) and a confidence, because
those deserve different amounts of trust. An unresolved status stays unresolved:
the dashboard says so and asks, rather than defaulting to a plausible one.

## Your name

Google's display name is not always the name somebody goes by. The dashboard
greeting has an inline "call me something else" control
(`showNicknameDialog`), stored on the session and persisted with it — local
only, and it never touches the name on a filing.

## Sign-in

Real Google Identity Services, not a stub — see `lib/services/auth_service.dart`.
Two things shape how it behaves:

- **On the web, GIS only authenticates from its own rendered button.** So the
  sign-in screen shows Google's button (`lib/widgets/google_sign_in_button*.dart`
  picks the right implementation per platform) and the result arrives on
  `authenticationEvents`, not from a callback on our button.
- **GIS does not keep a session.** It returns an ID token good for about an hour
  and forgets you. The "stay signed in for 14 days" behaviour is therefore an
  application-level session persisted in `shared_preferences`. A backend would
  upgrade this to a verified JWT + refresh token via `POST /api/auth/google`;
  the ID token is already carried on the session object for exactly that.

## The map

`/visa-pathways` uses a custom viewport (`lib/screens/pathways/graph_viewport.dart`)
rather than `InteractiveViewer`. The canvas is covered in node cards with their
own tap and hover handlers, which made drag-to-pan unreliable — you could zoom
but not reliably drag. Owning the gesture makes panning work anywhere, including
on top of a card, while a tap that never moves still selects the node.

Drag to pan · scroll to move · ctrl/⌘+scroll to zoom · pinch to zoom.

## Layout

```
lib/
├── main.dart                  # MaterialApp.router + text-scale clamp
├── app/router.dart            # go_router routes, /dashboard guard
├── theme/
│   ├── tokens.dart            # colours, spacing, radii, shadows (design doc)
│   └── app_theme.dart         # Inter type scale + ThemeData
├── models/
│   ├── pathway_graph.dart     # graph parsing + longest-path layered layout
│   ├── case_profile.dart      # where you are / where you want to be
│   └── intake_questionnaire.dart # the offline branching questionnaire
├── services/
│   ├── pathway_repository.dart# loads the graph (asset today, API later)
│   ├── case_service.dart      # intake calls + local storage of the case
│   └── auth_service.dart      # session state, nickname; real Google OAuth
├── widgets/                   # nav, footer, pills, badges, reveal-on-scroll
│   ├── hero_journey.dart      # the animated traveller + luggage
│   └── wavy_cta.dart          # the one sketched-tail CTA per page
└── screens/
    ├── landing/               # hero, how-it-works, map preview, features
    ├── signin/                # Google sign-in
    ├── pathways/              # the full graph: cards, edges, detail panel
    ├── intake/                # describe-it or answer-questions placement
    └── dashboard/             # personal page
```

## Design

Landing/marketing surfaces follow `docs/DESIGN_flowmapp_landing_page.md`: white
canvas, black display type, one saturated blue for action, full-pill controls,
1px hairline borders instead of shadows. The pastel set appears only as small
circular badges and category chips. Tokens live in `lib/theme/tokens.dart` —
change them there, not inline.

`docs/FRONTEND_UI_PRD.md` describes a second, wayfinding-flavoured direction for
the signed-in product screens (brass/paper stamps). The landing surface
deliberately follows the Flowmapp system; the two meet at the route-line and
"you are here" metaphors, which both directions share.

## Tests

```bash
flutter test                                   # unit + widget tests
flutter test test/screenshot_tool_test.dart    # renders each screen to build/screens/*.png
```

`screenshot_tool_test.dart` is a dev tool, not an assertion suite — it exists so
layout can be eyeballed without a browser.

## Not built yet

The agent chat, live deadlines and the O-1/EB-1 evidence tracker — all of which
need backend work that does not exist. Their surfaces are present as designed
mockups on the landing page and dashboard, and each dashboard panel is annotated
with the endpoint that will populate it. The deadline cards on the dashboard are
still sample data; the news panel and the status/goal stamp are not.

The confirmed case is stored on the device, keyed by account. It moves to the
server with `POST /api/case/confirm` (`backend/docs/API_ENDPOINTS.md` §3), at
which point `CaseService` becomes a cache rather than the source of truth — the
shape it stores is already the one that endpoint returns.
