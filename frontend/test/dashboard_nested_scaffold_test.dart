import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumos/screens/evidence/evidence_scaffold.dart';
import 'package:lumos/services/evidence_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the bug written up in `RCA-dashboard-unclickable.md`.
///
/// The dashboard embeds [EvidenceLoader] as one card inside its own [Scaffold]
/// and scroll view. While the catalog was still loading, the loader used to
/// answer with a whole page shell of its own. A [Scaffold] nested in a scroll
/// view is handed unbounded height, so layout threw, every render box below it
/// was left unsized, and the first hit test after that escaped through
/// `MouseTracker._deviceUpdatePhase` without clearing its lock — wedging the
/// mouse tracker for the rest of the page's life. Every pointer event after
/// that was dropped, so the whole dashboard stopped responding until reload.
///
/// The window only opens once the case profile arrives, mid-interaction, which
/// is why this reproduced on a manual sign-in and never on a refresh.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Back to "not loaded", so `load()` is genuinely pending on the first
    // frame and the waiting branch is the one under test. The catalog is
    // installed through the seam because `rootBundle` does not serve assets
    // under `flutter test`.
    EvidenceService.instance.forget();
    EvidenceService.instance.useCatalog(EvidenceService.embeddedCatalog());
  });

  /// A desktop-width surface: the shared nav lays out its full row above
  /// [Breaks.mobile], and the default 800x600 test window is too narrow for it.
  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// A router is the minimum the shared nav needs — it reads the current route
  /// to mark the active link.
  Widget hosted(Widget child) => MaterialApp.router(
    routerConfig: GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => child)],
    ),
  );

  /// The shape of the dashboard around the panel: a scroll view, which hands
  /// its child unbounded height.
  Widget dashboardShell(Widget panel) => Scaffold(
    body: Column(
      children: [
        Expanded(
          child: SingleChildScrollView(child: Column(children: [panel])),
        ),
      ],
    ),
  );

  testWidgets('an embedded loader never adds a second Scaffold', (tester) async {
    useDesktopSurface(tester);

    await tester.pumpWidget(
      hosted(
        dashboardShell(
          EvidenceLoader(
            standalone: false,
            builder: (_, _) => const Text('catalog ready'),
          ),
        ),
      ),
    );

    // First frame: the future has not resolved, so this is the branch that
    // used to return a page of its own.
    expect(find.byType(EvidenceScaffold), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();

    expect(find.text('catalog ready'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a standalone loader still shows the page shell while it waits', (
    tester,
  ) async {
    useDesktopSurface(tester);

    await tester.pumpWidget(
      hosted(
        EvidenceLoader(
          builder: (_, _) =>
              const EvidenceScaffold(children: [Text('catalog ready')]),
        ),
      ),
    );

    expect(find.byType(EvidenceScaffold), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();

    expect(find.text('catalog ready'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
