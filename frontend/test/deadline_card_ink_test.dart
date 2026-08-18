import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/models/deadline.dart';
import 'package:lumos/widgets/deadline_card.dart';

/// A non-lead [DeadlineCard] folds its detail away behind an [ExpansionTile],
/// whose header is a [ListTile]. A ListTile paints its ink splash onto the
/// nearest [Material] ancestor, and the card's own opaque background sits in
/// between — so the splash was invisible and Flutter asserted about it on
/// every single build. Thirty-five of those filled the console on one visit to
/// the dashboard.
void main() {
  const deadline = Deadline(
    id: 'derived.test',
    title: 'Test deadline',
    description: 'Why this deadline exists.',
    consequence: 'What happens if it slips.',
  );

  Future<void> pumpCard(WidgetTester tester, {required bool lead}) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DeadlineCard(
              deadline: deadline,
              now: DateTime(2026, 1, 1),
              lead: lead,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a folded card draws its ink splash without asserting', (
    tester,
  ) async {
    await pumpCard(tester, lead: false);

    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Expanding is what actually splashes, so exercise it too.
    await tester.tap(find.text('Why this is here'));
    await tester.pumpAndSettle();

    expect(find.text('Why this deadline exists.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lead card shows its detail outright, with no tile', (
    tester,
  ) async {
    await pumpCard(tester, lead: true);

    expect(find.byType(ExpansionTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
