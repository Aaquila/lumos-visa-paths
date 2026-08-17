import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumos/models/case_profile.dart';
import 'package:lumos/models/intake_questionnaire.dart';
import 'package:lumos/models/onboarding_profile.dart';
import 'package:lumos/models/pathway_graph.dart';
import 'package:lumos/screens/dashboard/dashboard_page.dart';
import 'package:lumos/screens/intake/intake_page.dart';
import 'package:lumos/screens/onboarding/name_picker_page.dart';
import 'package:lumos/screens/onboarding/situation_page.dart';
import 'package:lumos/services/auth_service.dart';
import 'package:lumos/services/case_service.dart';
import 'package:lumos/services/pathway_repository.dart';
import 'package:lumos/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

PathwayGraph loadGraph() => PathwayGraph.fromJson(
  jsonDecode(File(PathwayRepository.assetPath).readAsStringSync())
      as Map<String, dynamic>,
);

/// Walks a questionnaire branch by option label, so the test reads like the
/// clicks a person would make.
List<IntakeOption> walk(String startStepId, List<String> labels) {
  final path = <IntakeOption>[];
  var stepId = startStepId;
  for (final label in labels) {
    final step = Questionnaire.step(stepId);
    final option = step.options.firstWhere(
      (o) => o.label == label,
      orElse: () => throw StateError('no "$label" in step ${step.id}'),
    );
    path.add(option);
    if (option.next != null) stepId = option.next!;
  }
  return path;
}

void main() {
  late PathwayGraph graph;
  setUpAll(() => graph = loadGraph());

  group('questionnaire', () {
    test('every id it can produce is a real node on the map', () {
      final ids = {for (final n in graph.nodes) n.id};
      for (final step in Questionnaire.steps.values) {
        for (final option in step.options) {
          if (option.nodeId != null) {
            expect(ids, contains(option.nodeId), reason: option.label);
          }
          for (final alternative in option.alternatives) {
            expect(ids, contains(alternative), reason: option.label);
          }
        }
      }
    });

    test('every follow-up step it points at exists, and terminates', () {
      for (final step in Questionnaire.steps.values) {
        expect(step.options, isNotEmpty, reason: step.id);
        for (final option in step.options) {
          if (option.next != null) {
            expect(
              Questionnaire.steps,
              contains(option.next),
              reason: '${step.id} → ${option.label}',
            );
            expect(
              option.next,
              isNot(step.id),
              reason: 'a step must not loop back to itself',
            );
          } else {
            // A terminal option either resolves a status or explains why it
            // does not — a silent dead end would leave the user nowhere.
            expect(
              option.nodeId != null || option.note != null,
              isTrue,
              reason: '${step.id} → ${option.label}',
            );
          }
        }
      }
    });

    test('a full walk resolves to the status and goal that were chosen', () {
      final profile = Questionnaire.resolve(
        statusPath: walk(Questionnaire.statusRoot, [
          'I am studying in the US on an F-1',
          'STEM OPT extension',
        ]),
        goalPath: walk(Questionnaire.goalRoot, [
          'A green card through my work',
        ]),
      );

      expect(profile.currentNodeId, 'student.stem_opt');
      expect(profile.currentConfidence, 'high');
      expect(profile.goalNodeId, 'employment_gc.eb2');
      expect(
        profile.alternativeGoalIds,
        contains('employment_gc.eb2_niw'),
        reason: 'a direction, not a destination — show the sibling routes',
      );
      expect(profile.source, CaseSource.questionnaire);
      expect(profile.explanation, contains('STEM OPT extension'));
    });

    test('"none of these" resolves to no status rather than a default one', () {
      final profile = Questionnaire.resolve(
        statusPath: walk(Questionnaire.statusRoot, ['None of these']),
        goalPath: const [],
      );

      expect(profile.currentNodeId, isNull);
      expect(profile.isResolved, isFalse);
      expect(profile.currentConfidence, 'low');
      expect(profile.explanation, isNotEmpty);
    });

    test('skipping the goal leaves it unset, not guessed', () {
      final profile = Questionnaire.resolve(
        statusPath: walk(Questionnaire.statusRoot, [
          'I already have a green card',
          'A ten-year card',
        ]),
        goalPath: const [],
      );

      expect(profile.currentNodeId, 'post_lpr.lpr');
      expect(profile.hasGoal, isFalse);
      expect(profile.goalConfidence, 'low');
    });
  });

  group('case profile wire format', () {
    test('survives a round trip through storage', () {
      final before = Questionnaire.resolve(
        statusPath: walk(Questionnaire.statusRoot, [
          'I am working in the US on a temporary work visa',
          'H-1B',
        ]),
        goalPath: walk(Questionnaire.goalRoot, ['US citizenship']),
      );
      final after = CaseProfile.fromJson(
        jsonDecode(jsonEncode(before.toJson())) as Map<String, dynamic>,
      );

      expect(after.currentNodeId, before.currentNodeId);
      expect(after.goalNodeId, before.goalNodeId);
      expect(after.source, before.source);
      expect(after.facts.length, before.facts.length);
    });

    test('parses the backend intake response, questions included', () {
      final profile = CaseProfile.fromJson({
        'current_node_id': 'student.opt_postcompletion',
        'current_confidence': 'high',
        'goal_node_id': 'temp_worker.h1b',
        'goal_confidence': 'medium',
        'alternative_goal_ids': ['intracompany.l1'],
        'facts': [
          {'label': 'Degree', 'value': 'MS, finished in May'},
        ],
        'questions': [
          {'id': 'q_stem', 'text': 'Was your degree on the STEM list?'},
        ],
        'explanation': 'You described post-graduation training.',
        'source': 'llm',
        'degraded': false,
      });

      expect(profile.source, CaseSource.agent);
      expect(profile.questions.single, 'Was your degree on the STEM list?');
      expect(profile.facts.single.label, 'Degree');
      expect(profile.degraded, isFalse);
    });
  });

  group('intake page', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      CaseService.instance.forget();
    });

    /// A router with the one destination intake navigates to, so accepting a
    /// proposal is exercised end to end rather than up to the last step.
    Widget wrap(Widget child) => MaterialApp.router(
      theme: AppTheme.build(),
      routerConfig: GoRouter(
        routes: [
          GoRoute(path: '/', builder: (context, state) => child),
          GoRoute(
            path: '/dashboard',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('dashboard'))),
          ),
        ],
      ),
    );

    /// The desktop nav needs ~1000px before it collapses to its compact form;
    /// the default 800×600 test window overflows it.
    void desktopWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1440, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('offers both paths, and questions work with no backend', (
      tester,
    ) async {
      // The test binding answers every HTTP request with a failure, so this is
      // also the "intake service is down" case: the questions must still work.
      desktopWindow(tester);
      await tester.pumpWidget(wrap(const IntakePage()));
      await tester.pumpAndSettle();

      expect(find.text('Describe it in your own words'), findsOneWidget);
      expect(find.text('Answer a few questions'), findsOneWidget);

      await tester.tap(find.text('Start the questions'));
      await tester.pumpAndSettle();
      expect(find.text('Which of these describes you today?'), findsOneWidget);

      await tester.tap(find.text('I already have a green card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A ten-year card'));
      await tester.pumpAndSettle();

      expect(find.text('Where would you like to end up?'), findsOneWidget);
      await tester.tap(find.text('US citizenship'));
      await tester.pumpAndSettle();

      // A proposal, not a commitment: nothing is stored until it is accepted.
      expect(find.text('YOU ARE HERE'), findsOneWidget);
      expect(find.text('Use this as my pathway'), findsOneWidget);
      expect(CaseService.instance.profile, isNull);

      await tester.tap(find.text('Use this as my pathway'));
      await tester.pumpAndSettle();
      expect(CaseService.instance.profile?.currentNodeId, 'post_lpr.lpr');
      expect(
        CaseService.instance.profile?.goalNodeId,
        'post_lpr.naturalization',
      );
    });

    testWidgets('back steps out of a branch without losing the walk', (
      tester,
    ) async {
      desktopWindow(tester);
      await tester.pumpWidget(
        wrap(const IntakePage(startInQuestionnaire: true)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('I am studying in the US on an F-1'));
      await tester.pumpAndSettle();
      expect(find.text('Which part of F-1 are you in?'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Which of these describes you today?'), findsOneWidget);

      await tester.tap(find.text('I am on a J-1 exchange program'));
      await tester.pumpAndSettle();
      expect(find.text('Where would you like to end up?'), findsOneWidget);
    });
  });

  group('dashboard', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      CaseService.instance.forget();
      await AuthService.instance.continueAsDemoUser();
    });

    tearDown(() => AuthService.instance.signOut());

    Widget wrap(Widget child) => MaterialApp.router(
      theme: AppTheme.build(),
      routerConfig: GoRouter(
        routes: [GoRoute(path: '/', builder: (context, state) => child)],
      ),
    );

    testWidgets('asks for intake instead of showing a sample case', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(const DashboardPage()));
      await tester.pumpAndSettle();

      expect(find.text('Start with where you are'), findsOneWidget);
      expect(find.text('Set up my pathway'), findsOneWidget);
      expect(find.text('YOU ARE HERE'), findsNothing);
    });

    testWidgets('shows the confirmed case once intake has run', (tester) async {
      tester.view.physicalSize = const Size(1440, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await CaseService.instance.save(
        Questionnaire.resolve(
          statusPath: walk(Questionnaire.statusRoot, [
            'I am studying in the US on an F-1',
            'STEM OPT extension',
          ]),
          goalPath: walk(Questionnaire.goalRoot, ['US citizenship']),
        ),
      );

      await tester.pumpWidget(wrap(const DashboardPage()));
      // Not pumpAndSettle: the route strip animates continuously, so settling
      // never completes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('YOU ARE HERE'), findsOneWidget);
      expect(find.text('YOU WANT TO BE HERE'), findsOneWidget);
      expect(find.text('Redo intake'), findsOneWidget);
      expect(find.text('Set up my pathway'), findsNothing);
    });
  });

  group('name choice', () {
    UserSession session({String? chosenNameId}) => UserSession(
      displayName: 'Aleksandra Nowak',
      email: 'a.nowak@example.com',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      onboarding: OnboardingProfile(chosenNameId: chosenNameId),
    );

    test('offers exactly three visibly distinct names', () {
      expect(NameChoice.options.length, 3);
      expect(
        {for (final o in NameChoice.options) o.id}.length,
        3,
        reason: 'ids must be unique — they are what gets stored',
      );
      expect(
        {for (final o in NameChoice.options) o.avatar}.length,
        3,
        reason: 'each card must look different, not just read differently',
      );
      expect({for (final o in NameChoice.options) o.name}.length, 3);
    });

    test('falls back to the first name until one is picked', () {
      expect(session().preferredName, 'Aleksandra');
      expect(session().hasChosenName, isFalse);
      expect(session().chosenName, isNull);
    });

    test('the picked name wins', () {
      expect(session(chosenNameId: 'mira').preferredName, 'Mira');
      expect(session(chosenNameId: 'mira').chosenName, 'Mira');
      expect(session(chosenNameId: 'mira').hasChosenName, isTrue);
    });

    test('an id that is no longer offered reads as "not picked yet"', () {
      final restored = UserSession.fromJson(
        jsonDecode(jsonEncode(session(chosenNameId: 'gone').toJson()))
            as Map<String, dynamic>,
      );
      expect(restored.chosenName, isNull);
      expect(restored.preferredName, 'Aleksandra');
    });

    test('is carried through the stored session', () {
      final restored = UserSession.fromJson(
        jsonDecode(jsonEncode(session(chosenNameId: 'robin').toJson()))
            as Map<String, dynamic>,
      );
      expect(restored.chosenName, 'Robin');
      expect(restored.preferredName, 'Robin');
    });
  });

  group('visa situation', () {
    test('a year on its own is a complete answer', () {
      const situation = VisaSituation(changeYear: 2027);
      expect(situation.hasDate, isTrue);
      expect(situation.dateSummary, contains('2027'));
      expect(situation.dateSummary, isNot(contains('January')));
    });

    test('"I don\'t know" is an answer, not a blank', () {
      const situation = VisaSituation(dateUnknown: true);
      expect(situation.hasDate, isTrue);
      expect(situation.dateSummary, isNotEmpty);
    });

    test('free text and a chip are folded into one sentence', () {
      const situation = VisaSituation(
        statusText: 'My OPT started in June.',
        statusChip: 'F-1 student',
      );
      expect(situation.statusSummary, 'F-1 student. My OPT started in June.');
    });

    test('survives a round trip through the stored session', () {
      const situation = VisaSituation(
        statusText: 'I am on a student visa',
        statusChip: 'F-1 student',
        changeYear: 2026,
        changeMonth: 6,
        goalText: 'A green card eventually',
      );
      final restored = OnboardingProfile.fromJson(
        jsonDecode(
              jsonEncode(
                const OnboardingProfile(
                  chosenNameId: 'theo',
                  situation: situation,
                  situationDone: true,
                ).toJson(),
              ),
            )
            as Map<String, dynamic>,
      );

      expect(restored.chosenName, 'Theo');
      expect(restored.situation?.statusText, situation.statusText);
      expect(restored.situation?.changeMonth, 6);
      expect(restored.isComplete, isTrue);
    });
  });

  group('onboarding gate', () {
    test('routes a half-finished person back to where they stopped', () {
      expect(const OnboardingProfile().resumeRoute, '/onboarding/name');
      expect(
        const OnboardingProfile(chosenNameId: 'mira').resumeRoute,
        '/onboarding/situation',
      );
      expect(
        const OnboardingProfile(
          chosenNameId: 'mira',
          situationDone: true,
        ).resumeRoute,
        isNull,
        reason: 'a finished person goes straight to the dashboard',
      );
    });

    test('skipping step 2 still counts as finished', () async {
      SharedPreferences.setMockInitialValues({});
      await AuthService.instance.continueAsDemoUser();
      addTearDown(AuthService.instance.signOut);

      await AuthService.instance.chooseName('robin');
      expect(
        AuthService.instance.onboarding.resumeRoute,
        '/onboarding/situation',
      );

      await AuthService.instance.skipSituation();
      expect(AuthService.instance.onboarding.resumeRoute, isNull);
      expect(AuthService.instance.onboarding.situation, isNull);
      expect(AuthService.instance.session?.preferredName, 'Robin');
    });

    test('a name outside the three on offer is not stored', () async {
      SharedPreferences.setMockInitialValues({});
      await AuthService.instance.continueAsDemoUser();
      addTearDown(AuthService.instance.signOut);

      await AuthService.instance.chooseName('Bartholomew');
      expect(AuthService.instance.onboarding.hasName, isFalse);
    });

    test('the name can be changed again later', () async {
      SharedPreferences.setMockInitialValues({});
      await AuthService.instance.continueAsDemoUser();
      addTearDown(AuthService.instance.signOut);

      await AuthService.instance.chooseName('mira');
      await AuthService.instance.clearChosenName();
      expect(AuthService.instance.onboarding.hasName, isFalse);
      expect(AuthService.instance.onboarding.resumeRoute, '/onboarding/name');
    });
  });

  group('onboarding screens', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      CaseService.instance.forget();
      await AuthService.instance.continueAsDemoUser();
    });

    tearDown(() => AuthService.instance.signOut());

    Widget wrap(Widget child, {String initial = '/'}) => MaterialApp.router(
      theme: AppTheme.build(),
      routerConfig: GoRouter(
        initialLocation: initial,
        routes: [
          GoRoute(path: '/', builder: (context, state) => child),
          GoRoute(
            path: '/onboarding/situation',
            builder: (context, state) => const SituationPage(),
          ),
          GoRoute(
            path: '/onboarding/name',
            builder: (context, state) => const NamePickerPage(),
          ),
          GoRoute(
            path: '/dashboard',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('dashboard'))),
          ),
        ],
      ),
    );

    void tallWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1280, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('the name picker offers three names and no text box', (
      tester,
    ) async {
      tallWindow(tester);
      await tester.pumpWidget(wrap(const NamePickerPage()));
      await tester.pumpAndSettle();

      expect(find.text('What should I call you?'), findsOneWidget);
      for (final option in NameChoice.options) {
        expect(find.text(option.name), findsOneWidget);
      }
      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'the whole point is that nobody has to type a name',
      );
      expect(find.text('Step 1 of 2'), findsOneWidget);
    });

    testWidgets('picking a name stores it and moves to step 2', (tester) async {
      tallWindow(tester);
      await tester.pumpWidget(wrap(const NamePickerPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Theo'));
      await tester.pumpAndSettle();

      expect(AuthService.instance.onboarding.chosenName, 'Theo');
      expect(find.text('What\'s your situation right now?'), findsOneWidget);
      expect(find.textContaining('Step 2 of 2'), findsOneWidget);
    });

    testWidgets('step 2 always offers free text, chips are a shortcut', (
      tester,
    ) async {
      tallWindow(tester);
      // Step 1 is a precondition for step 2 in the real flow, and
      // `isComplete` below is `hasName && situationDone` — without this the
      // assertion only passes on state leaking in from another test.
      await AuthService.instance.chooseName('mira');
      await tester.pumpWidget(wrap(const SituationPage()));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('F-1 student'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField),
        'I am on a student visa, my OPT started in June',
      );
      await tester.tap(find.text('F-1 student'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('When does it change or run out?'), findsOneWidget);

      await tester.tap(find.text('I don\'t know'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('What would you like to happen?'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'I want to work in the US and eventually get a green card',
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final situation = AuthService.instance.onboarding.situation;
      expect(situation?.statusText, contains('OPT started in June'));
      expect(situation?.statusChip, 'F-1 student');
      expect(situation?.dateUnknown, isTrue);
      expect(situation?.goalText, contains('green card'));
      expect(AuthService.instance.onboarding.isComplete, isTrue);
      expect(find.text('dashboard'), findsOneWidget);
    });

    testWidgets('nothing in step 2 is a gate', (tester) async {
      tallWindow(tester);
      await tester.pumpWidget(wrap(const SituationPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Skip all'));
      await tester.pumpAndSettle();

      expect(find.text('dashboard'), findsOneWidget);
      expect(AuthService.instance.onboarding.situationDone, isTrue);
      expect(AuthService.instance.onboarding.situation, isNull);
    });

    testWidgets('intake opens pre-filled from what onboarding was told', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await AuthService.instance.chooseName('mira');
      await AuthService.instance.saveSituation(
        const VisaSituation(
          statusText: 'My OPT started in June.',
          statusChip: 'F-1 student',
          changeYear: 2027,
          goalText: 'A green card eventually.',
        ),
      );

      await tester.pumpWidget(wrap(const IntakePage()));
      await tester.pumpAndSettle();

      // Straight into the describe path, with the words already in the box —
      // not a second intake asking the same questions again. `_Panel` renders
      // its title uppercased, so match what is actually on screen.
      expect(find.text('IN YOUR OWN WORDS'), findsOneWidget);
      expect(
        find.textContaining('This is what you told me during setup'),
        findsOneWidget,
      );
      expect(find.textContaining('My OPT started in June.'), findsWidgets);
    });
  });
}
