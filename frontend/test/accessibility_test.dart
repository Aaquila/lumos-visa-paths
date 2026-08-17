import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/models/pathway_graph.dart';
import 'package:lumos/screens/pathways/node_card.dart';
import 'package:lumos/screens/pathways/pathways_page.dart';
import 'package:lumos/services/pathway_repository.dart';
import 'package:lumos/theme/app_theme.dart';
import 'package:lumos/theme/tokens.dart';
import 'package:lumos/widgets/badges.dart';
import 'package:lumos/widgets/hero_journey.dart';
import 'package:lumos/widgets/pill_button.dart';
import 'package:lumos/widgets/reveal.dart';
import 'package:lumos/widgets/wavy_cta.dart';

// ── Contrast maths ──────────────────────────────────────────────────────────
// WCAG 2.1 relative luminance and contrast ratio, so the palette audit is
// checked in CI rather than living in a document that goes stale.

double _channel(int v) {
  final c = v / 255.0;
  return c <= 0.03928
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4) as double;
}

double _luminance(Color c) =>
    0.2126 * _channel((c.r * 255).round()) +
    0.7152 * _channel((c.g * 255).round()) +
    0.0722 * _channel((c.b * 255).round());

/// Contrast ratio between two opaque colours, 1.0 … 21.0.
double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

Matcher closeToRatio(double expected) => closeTo(expected, 0.02);

// ── Harnesses ───────────────────────────────────────────────────────────────

Widget _app(Widget child, {bool reduceMotion = false, double textScale = 1.0}) {
  return MaterialApp(
    theme: AppTheme.build(),
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        backgroundColor: T.paper,
        body: Center(child: child),
      ),
    ),
  );
}

PathwayGraph _loadGraph() => PathwayGraph.fromJson(
  jsonDecode(File(PathwayRepository.assetPath).readAsStringSync())
      as Map<String, dynamic>,
);

/// `rootBundle` is not wired to the real asset directory under `flutter test`,
/// so `PathwayRepository.load()` would hang forever. Serve the bundled JSON off
/// the filesystem instead, which is the same bytes the app ships.
void _serveAssetsFromDisk() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (ByteData? message) async {
        final key = utf8.decode(message!.buffer.asUint8List());
        final file = File(key);
        if (!file.existsSync()) return null;
        return ByteData.view(file.readAsBytesSync().buffer);
      });
}

/// Pump the real page with its graph loaded.
///
/// The graph itself is loaded once in `setUpAll`, outside any fake-async zone:
/// `AssetBundle.loadString` decodes large payloads on a worker isolate, which
/// `testWidgets` fake async never lets run. Because [PathwayRepository] caches
/// the future, the page's own `load()` here resolves on the next microtask.
Future<void> _pumpPathwaysPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // `rootBundle.loadString` finishes its work off the fake-async zone, so a
  // future created inside `testWidgets` never completes no matter how long we
  // pump — the page would sit on its spinner forever. `runAsync` steps outside
  // that zone so the load can actually finish; [PathwayRepository] then caches
  // it, and the page's own `load()` in `initState` resolves on a microtask.
  // The page loads its graph from `rootBundle` in `initState`. A future that
  // resolves outside the fake-async zone never completes inside it, so pumping
  // normally would leave the page on its spinner forever — which is also what
  // makes `pumpAndSettle` time out, the spinner being an endless animation.
  // Mounting inside `runAsync` lets that load actually finish; the frames are
  // then settled back in fake time.
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.build(), home: const PathwaysPage()),
    );
    await PathwayRepository.instance.load();
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    _serveAssetsFromDisk();
    await PathwayRepository.instance.load();
  });

  // ── 1. Contrast audit ─────────────────────────────────────────────────────

  group('palette contrast (WCAG 2.1 AA)', () {
    test('body and caption text clears 4.5:1 on paper', () {
      // Graphite is the workhorse text colour for body, bodySm and — after
      // this refactor — caption.
      expect(contrastRatio(T.graphite, T.paper), closeToRatio(5.13));
      expect(contrastRatio(T.carbon, T.paper), closeToRatio(15.91));
      expect(contrastRatio(T.ink, T.paper), closeToRatio(21.0));

      for (final style in [AppTheme.body, AppTheme.bodySm, AppTheme.caption]) {
        expect(
          contrastRatio(style.color!, T.paper),
          greaterThanOrEqualTo(4.5),
          reason: 'text style ${style.fontSize}px must clear 4.5:1',
        );
      }
    });

    test('Pencil Gray is a border token, never a text token', () {
      // 2.84:1 — below both the 4.5:1 text bar and the 3:1 UI-boundary bar.
      // Recorded here so that anyone tempted to use it for type sees why not.
      expect(contrastRatio(T.pencilGray, T.paper), closeToRatio(2.84));
      expect(contrastRatio(T.pencilGray, T.paper), lessThan(3.0));

      expect(AppTheme.caption.color, isNot(T.pencilGray));
      expect(AppTheme.body.color, isNot(T.pencilGray));
      expect(AppTheme.bodySm.color, isNot(T.pencilGray));
    });

    test('Signal Blue is documented as a known, unfixed AA failure', () {
      // 3.8:1. Fine as large text (the 18px hero CTA clears the 3:1 large-text
      // bar) and as a UI boundary, but it fails 4.5:1 for the 14px pill labels,
      // the 12px footer links and the 12px source URLs.
      //
      // NOT fixed here: Signal Blue is the single brand accent and changing it
      // is a design decision, not an accessibility refactor. Recommended
      // replacement is #0067CC (5.51:1), which is the same hue at a darker
      // value. This test pins the current state so the change is deliberate.
      expect(contrastRatio(T.signalBlue, T.paper), closeToRatio(3.8));
      expect(contrastRatio(T.signalBlue, T.paper), greaterThanOrEqualTo(3.0));
      expect(
        contrastRatio(const Color(0xFF0067CC), T.paper),
        greaterThanOrEqualTo(4.5),
        reason: 'the recommended replacement does clear AA',
      );
    });

    test('pastel icon badges carry Ink glyphs well clear of 4.5:1', () {
      const pastels = {
        'yellow': T.pastelYellow,
        'mint': T.pastelMint,
        'pink': T.pastelPink,
        'lavender': T.pastelLavender,
        'peach': T.pastelPeach,
        'sky': T.pastelSky,
      };
      pastels.forEach((name, fill) {
        expect(
          contrastRatio(T.ink, fill),
          greaterThanOrEqualTo(4.5),
          reason: 'ink on pastel $name',
        );
      });
    });
  });

  // ── 2. Built-in Flutter accessibility guidelines ──────────────────────────

  group('flutter_test accessibility guidelines', () {
    testWidgets('shared widgets meet the text contrast guideline', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              StepBadge(step: 'Why this exists', descriptor: 'the honest one'),
              SizedBox(height: 8),
              MetaPill(label: 'Modelled now', icon: Icons.check_circle_outline),
              SizedBox(height: 8),
              PillButton(label: 'Secondary action'),
            ],
          ),
        ),
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });

    testWidgets('every interactive control has an accessible name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          reduceMotion: true,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PillButton(label: 'Get started', onPressed: () {}),
              const SizedBox(height: 8),
              WavyCta(label: 'Sign in', onPressed: () {}),
            ],
          ),
        ),
      );
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('the pathway list view meets tap target and label guidelines', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final graph = _loadGraph();
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 800,
            height: 600,
            child: PathwayListView(
              graph: graph,
              visible: {for (final n in graph.nodes) n.id},
              selectedId: null,
              onSelect: (_) {},
            ),
          ),
        ),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });

  // ── 3. The graph is reachable without a mouse or eyes ─────────────────────

  group('pathway graph semantics', () {
    testWidgets('a node card announces its name, category and route counts', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final graph = _loadGraph();
      final node = graph.nodes.first;

      await tester.pumpWidget(
        _app(
          NodeCard(
            node: node,
            categoryLabel: 'Students',
            selected: false,
            dimmed: false,
            semanticLabel: '${node.name}. Students. 2 routes out, 1 route in.',
            onTap: () {},
            onHover: (_) {},
          ),
        ),
      );

      expect(
        find.bySemanticsLabel(
          '${node.name}. Students. 2 routes out, 1 route in.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a node card is focusable and activates on Enter', (
      tester,
    ) async {
      var taps = 0;
      final graph = _loadGraph();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _app(
          NodeCard(
            node: graph.nodes.first,
            categoryLabel: 'Students',
            selected: false,
            dimmed: false,
            focusNode: focusNode,
            onTap: () => taps++,
            onHover: (_) {},
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue, reason: 'card must accept focus');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1, reason: 'Enter must open the status');

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(taps, 2, reason: 'Space must open the status too');
    });

    testWidgets('the list view exposes every route as a labelled button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final graph = _loadGraph();
      // Pick a status that definitely has routes out, and open it.
      final node = graph.nodes.firstWhere(
        (n) => graph.edgesFrom(n.id).isNotEmpty,
      );
      final target = graph.edgesFrom(node.id).first;
      final targetName = graph.node(target.to)!.name;

      String? selected;
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 800,
            height: 600,
            child: PathwayListView(
              graph: graph,
              visible: {for (final n in graph.nodes) n.id},
              selectedId: node.id,
              onSelect: (id) => selected = id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The expanded status spells out where each edge goes — the information
      // the painted arrows carry visually.
      final route = find.bySemanticsLabel(
        RegExp('Leads to ${RegExp.escape(targetName)}'),
      );
      expect(route, findsWidgets);

      await tester.tap(route.first, warnIfMissed: false);
      await tester.pump();
      expect(selected, target.to);
      handle.dispose();
    });
  });

  // ── 4. Keyboard navigation of the live page ───────────────────────────────

  group('pathway graph keyboard navigation', () {
    testWidgets(
      'arrow keys walk between statuses and Escape closes the panel',
      (tester) async {
        await _pumpPathwaysPage(tester);

        final cards = find.byType(NodeCard);
        expect(cards, findsWidgets, reason: 'graph should have rendered');

        // Nothing is focused yet: the first arrow press adopts a starting node
        // rather than doing nothing.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();

        FocusNode? focused() => tester
            .widgetList<Focus>(find.byType(Focus))
            .map((f) => f.focusNode)
            .firstWhere((n) => n?.hasPrimaryFocus == true, orElse: () => null);

        final first = focused();
        expect(first, isNotNull, reason: 'a status must take focus');

        // Walking right again must land somewhere else.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(focused(), isNot(same(first)));

        // Enter opens the detail panel …
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.close), findsWidgets);

        // … and Escape closes it again.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.close), findsNothing);
      },
    );

    testWidgets('+, - and 0 drive zoom through the viewport API', (
      tester,
    ) async {
      await _pumpPathwaysPage(tester);

      double zoomPercent() {
        final label = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .firstWhere(
              (d) => d != null && RegExp(r'^\d+%$').hasMatch(d),
              orElse: () => null,
            );
        return double.parse(label!.replaceAll('%', ''));
      }

      final start = zoomPercent();

      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pumpAndSettle();
      expect(zoomPercent(), greaterThan(start), reason: '+ must zoom in');

      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.pumpAndSettle();
      expect(zoomPercent(), lessThanOrEqualTo(start + 1));

      // 0 refits, which on this viewport returns to the starting scale.
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pumpAndSettle();
      expect(zoomPercent(), closeTo(start, 1));
    });

    testWidgets(
      'the map has a list-view equivalent reachable from the toolbar',
      (tester) async {
        await _pumpPathwaysPage(tester);

        expect(find.byType(PathwayListView), findsNothing);
        await tester.tap(find.text('Show list view'));
        await tester.pumpAndSettle();

        expect(find.byType(PathwayListView), findsOneWidget);
        expect(find.byType(NodeCard), findsNothing);
      },
    );
  });

  // ── 5. Reduced motion ─────────────────────────────────────────────────────

  group('reduced motion', () {
    testWidgets('Reveal shows its child immediately, with no opacity layer', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(reduceMotion: true, const Reveal(child: Text('Hello'))),
      );
      await tester.pump();

      expect(find.text('Hello'), findsOneWidget);
      // The fade-and-rise wrappers must be gone entirely, not merely finished:
      // a 0-opacity first frame is exactly the flicker this setting prevents.
      expect(
        find.descendant(
          of: find.byType(Reveal),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(Reveal),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
    });

    testWidgets('Reveal still animates when motion is allowed', (tester) async {
      await tester.pumpWidget(
        _app(reduceMotion: false, const Reveal(child: Text('Hello'))),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(Reveal),
          matching: find.byType(Opacity),
        ),
        findsOneWidget,
        reason: 'the animated path should be unchanged for everyone else',
      );
    });

    testWidgets('the hero journey settles instead of looping forever', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          reduceMotion: true,
          const SizedBox(width: 900, child: HeroJourney()),
        ),
      );
      // pumpAndSettle times out against an endlessly repeating controller, so
      // this completing at all is the assertion.
      await tester.pumpAndSettle();
      expect(find.byType(HeroJourney), findsOneWidget);
    });

    testWidgets('the hero journey still describes itself to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          reduceMotion: true,
          const SizedBox(width: 900, child: HeroJourney()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(RegExp('example visa route')),
        findsOneWidget,
        reason: 'a painted canvas needs a text equivalent',
      );
      // Each checkpoint on the rail must be named, not just the illustration.
      for (final stop in kDefaultJourney) {
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(stop.label))),
          findsWidgets,
        );
      }
      handle.dispose();
    });

    testWidgets('the wavy CTA stops rolling its edge', (tester) async {
      await tester.pumpWidget(
        _app(
          reduceMotion: true,
          WavyCta(label: 'Get started', onPressed: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WavyCta), findsOneWidget);
    });
  });

  // ── 6. Text scaling ───────────────────────────────────────────────────────

  testWidgets('controls survive a 2x browser font size without overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        textScale: 2.0,
        reduceMotion: true,
        SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PillButton(label: 'Get started', onPressed: () {}),
              const SizedBox(height: 8),
              const StepBadge(step: 'Privacy', descriptor: 'plainly'),
              const SizedBox(height: 8),
              const MetaPill(label: 'Modelled now'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A RenderFlex overflow reports itself as an exception during layout.
    expect(tester.takeException(), isNull);
  });
}
