// Dev tool: renders each screen to a PNG so layout can be eyeballed without a
// browser. Run with: flutter test test/screenshot_tool_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/models/case_profile.dart';
import 'package:lumos/screens/dashboard/dashboard_page.dart';
import 'package:lumos/screens/intake/intake_page.dart';
import 'package:lumos/screens/landing/landing_page.dart';
import 'package:lumos/screens/news/news_page.dart';
import 'package:lumos/screens/pathways/pathways_page.dart';
import 'package:lumos/screens/signin/signin_page.dart';
import 'package:lumos/services/auth_service.dart';
import 'package:lumos/services/case_service.dart';
import 'package:lumos/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> shoot(
  WidgetTester tester,
  String name,
  Widget page, {
  Size size = const Size(1440, 1000),
  double scrollBy = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(theme: AppTheme.build(), home: page),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 900));

  if (scrollBy != 0) {
    // jumpTo rather than a simulated drag: a drag synthesises hundreds of
    // pointer moves against a page full of live animations, which takes
    // minutes in the test renderer for no extra fidelity.
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(scrollBy);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
  }

  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final out = File('build/screens/$name.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote ${out.path}');
}

void main() {
  // Per-test, not setUpAll: the binding resets registered fonts between tests,
  // and without this the renderer draws every glyph as a box.
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader(AppTheme.fontFamily);
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Inter-$weight.ttf'));
    }
    await loader.load();
  });

  testWidgets('landing hero', (t) async {
    await shoot(t, 'landing_hero', const LandingPage());
  });

  testWidgets('landing scrolled', (t) async {
    await shoot(t, 'landing_how', const LandingPage(), scrollBy: 1150);
  });

  testWidgets('landing map section', (t) async {
    await shoot(t, 'landing_map', const LandingPage(), scrollBy: 2100);
  });

  testWidgets('landing features', (t) async {
    await shoot(t, 'landing_features', const LandingPage(), scrollBy: 3200);
  });

  testWidgets('signin', (t) async {
    await shoot(t, 'signin', const SignInPage());
  });

  testWidgets('pathways', (t) async {
    await shoot(t, 'pathways', const PathwaysPage());
  });

  testWidgets('pathways with selection', (t) async {
    await shoot(
      t,
      'pathways_selected',
      const PathwaysPage(focusNodeId: 'temp_worker.h1b'),
    );
  });

  testWidgets('dashboard before intake', (t) async {
    SharedPreferences.setMockInitialValues({});
    CaseService.instance.forget();
    await AuthService.instance.continueAsDemoUser();
    addTearDown(AuthService.instance.signOut);
    await shoot(t, 'dashboard', const DashboardPage());
  });

  testWidgets('dashboard with a confirmed case', (t) async {
    SharedPreferences.setMockInitialValues({});
    await AuthService.instance.continueAsDemoUser();
    addTearDown(AuthService.instance.signOut);
    await CaseService.instance.save(
      CaseProfile(
        currentNodeId: 'student.stem_opt',
        currentConfidence: 'high',
        goalNodeId: 'employment_gc.eb2',
        goalConfidence: 'medium',
        explanation:
            'You described post-graduation training on a STEM degree, so you '
            'are on the STEM OPT extension.',
        source: CaseSource.agent,
        updatedAt: DateTime(2026, 8, 12),
      ),
    );
    addTearDown(CaseService.instance.forget);
    await shoot(t, 'dashboard_resolved', const DashboardPage());
  });

  testWidgets('intake', (t) async {
    SharedPreferences.setMockInitialValues({});
    CaseService.instance.forget();
    await shoot(t, 'intake', const IntakePage());
  });

  testWidgets('intake questions', (t) async {
    SharedPreferences.setMockInitialValues({});
    CaseService.instance.forget();
    await shoot(
      t,
      'intake_questions',
      const IntakePage(startInQuestionnaire: true),
    );
  });

  testWidgets('news', (t) async {
    await shoot(t, 'news', const NewsPage());
  });

  testWidgets('landing mobile', (t) async {
    await shoot(
      t,
      'landing_mobile',
      const LandingPage(),
      size: const Size(420, 900),
    );
  });
}
