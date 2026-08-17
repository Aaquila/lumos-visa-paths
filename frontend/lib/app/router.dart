import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/dashboard/dashboard_page.dart';
import '../screens/deadlines/deadlines_page.dart';
import '../screens/evidence/evidence_criterion_page.dart';
import '../screens/evidence/evidence_overview_page.dart';
import '../screens/evidence/evidence_set_page.dart';
import '../screens/intake/intake_page.dart';
import '../screens/landing/landing_page.dart';
import '../screens/news/news_page.dart';
import '../screens/onboarding/name_picker_page.dart';
import '../screens/onboarding/situation_page.dart';
import '../screens/pathways/pathways_page.dart';
import '../screens/settings/notification_settings_page.dart';
import '../screens/signin/signin_page.dart';
import '../services/auth_service.dart';

/// `/` is the landing page — where a first-time visitor arrives.
/// `/signin` is the Google sign-in screen behind "Get started".
/// `/visa-pathways` is the full interactive graph, open without an account.
/// `/onboarding/name` and `/onboarding/situation` are the two questions asked
/// once, straight after sign-in.
/// `/intake` places a person on that graph; `/dashboard` is their personal
/// page. `/deadlines`, `/settings/notifications` and the `/evidence` tree are
/// personal too. Those are the guarded routes — everything else is public, so a
/// visitor can explore the map before deciding to sign in.
///
/// The flow is: sign in → name → situation → dashboard. [_guard] enforces it
/// from the session, which `main()` restores before the first frame, so a
/// returning person who finished onboarding never sees either step again and
/// somebody who closed the tab half way lands back on the question they left.
final appRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: AuthService.instance,
  redirect: _guard,
  routes: [
    GoRoute(
      path: '/',
      pageBuilder: (context, state) => _fade(state, const LandingPage()),
    ),
    GoRoute(
      path: '/signin',
      pageBuilder: (context, state) => _fade(state, const SignInPage()),
    ),
    GoRoute(
      path: '/visa-pathways',
      pageBuilder: (context, state) => _fade(
        state,
        PathwaysPage(focusNodeId: state.uri.queryParameters['node']),
      ),
    ),
    GoRoute(
      path: '/news',
      pageBuilder: (context, state) =>
          _fade(state, NewsPage(nodeId: state.uri.queryParameters['node'])),
    ),
    GoRoute(
      path: '/onboarding/name',
      pageBuilder: (context, state) => _fade(
        state,
        NamePickerPage(isChange: state.uri.queryParameters['change'] == '1'),
      ),
    ),
    GoRoute(
      path: '/onboarding/situation',
      pageBuilder: (context, state) => _fade(state, const SituationPage()),
    ),
    GoRoute(
      path: '/intake',
      pageBuilder: (context, state) => _fade(
        state,
        IntakePage(
          startInQuestionnaire:
              state.uri.queryParameters['mode'] == 'questions',
        ),
      ),
    ),
    GoRoute(
      path: '/dashboard',
      pageBuilder: (context, state) => _fade(state, const DashboardPage()),
    ),
    GoRoute(
      path: '/deadlines',
      pageBuilder: (context, state) => _fade(state, const DeadlinesPage()),
    ),
    GoRoute(
      path: '/settings/notifications',
      pageBuilder: (context, state) =>
          _fade(state, const NotificationSettingsPage()),
    ),
    // The evidence tracker is three levels deep — all categories, one
    // category, one criterion — and every level is guarded, because it reads
    // and writes that person's own self-assessment.
    GoRoute(
      path: '/evidence',
      pageBuilder: (context, state) =>
          _fade(state, const EvidenceOverviewPage()),
    ),
    GoRoute(
      path: '/evidence/:setId',
      pageBuilder: (context, state) => _fade(
        state,
        EvidenceSetPage(setId: state.pathParameters['setId'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/evidence/:setId/:itemId',
      pageBuilder: (context, state) => _fade(
        state,
        EvidenceCriterionPage(
          setId: state.pathParameters['setId'] ?? '',
          itemId: state.pathParameters['itemId'] ?? '',
        ),
      ),
    ),
  ],
  errorBuilder: (context, state) => _NotFound(location: state.uri.toString()),
);

/// The routes that need an account, matched exactly.
const _guarded = {
  '/intake',
  '/dashboard',
  '/deadlines',
  '/settings/notifications',
};

/// Guarded route *trees*. `/evidence` has path parameters below it, so exact
/// matching would let `/evidence/eb1a` slip past the gate that `/evidence`
/// enforces.
const _guardedPrefixes = ['/evidence'];

/// Whether [location] is behind the account gate. Exact matches and whole
/// subtrees are both guarded; keep new private routes going through here rather
/// than testing [_guarded] directly.
bool _needsAccount(String location) =>
    _guarded.contains(location) ||
    _guardedPrefixes.any((p) => location == p || location.startsWith('$p/'));

/// Sign-in gate and onboarding gate in one place, because they are one
/// question: "is this person ready to see their own page yet?"
String? _guard(BuildContext context, GoRouterState state) {
  final auth = AuthService.instance;
  final location = state.matchedLocation;
  final inOnboarding = location.startsWith('/onboarding');

  if (!auth.isSignedIn) {
    return (inOnboarding || _needsAccount(location)) ? '/signin' : null;
  }

  // Re-choosing a name later is a deliberate visit, not an unfinished step.
  if (inOnboarding && state.uri.queryParameters['change'] == '1') return null;

  final resume = auth.onboarding.resumeRoute;

  if (inOnboarding) {
    if (resume == null) return '/dashboard';
    // Let them walk back to step 1 from step 2 without being bounced forward.
    if (location == '/onboarding/name' || location == resume) return null;
    return resume;
  }

  if (_needsAccount(location) && resume != null) return resume;
  return null;
}

/// Routes cross-fade rather than slide — the pages share a canvas, so a push
/// transition would read as a modal.
CustomTransitionPage<void> _fade(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 260),
      transitionsBuilder: (context, animation, secondary, child) =>
          FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          ),
    );

class _NotFound extends StatelessWidget {
  const _NotFound({required this.location});

  final String location;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No route here: $location'),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => context.go('/'),
              child: const Text('Back to the landing page'),
            ),
          ],
        ),
      ),
    );
  }
}
