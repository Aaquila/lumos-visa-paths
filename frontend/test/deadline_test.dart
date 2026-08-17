import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/models/case_profile.dart';
import 'package:lumos/models/deadline.dart';
import 'package:lumos/models/onboarding_profile.dart';
import 'package:lumos/models/pathway_graph.dart';
import 'package:lumos/services/auth_service.dart';
import 'package:lumos/services/deadline_service.dart';
import 'package:lumos/services/pathway_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

PathwayGraph loadGraph() => PathwayGraph.fromJson(
  jsonDecode(File(PathwayRepository.assetPath).readAsStringSync())
      as Map<String, dynamic>,
);

/// A fixed clock. Every time-dependent assertion in here is measured against
/// this and nothing else — the production code never reads the real clock, so
/// none of these tests can go flaky at midnight or in another timezone.
final now = DateTime(2026, 8, 15);

Deadline at(DateTime? due, {bool approximate = false, String id = 'x'}) =>
    Deadline(
      id: id,
      title: 'A thing',
      description: '',
      dueDate: due,
      isApproximate: approximate,
      approximateLabel: approximate && due != null
          ? '${Deadline.monthName(due.month)} ${due.year}'
          : null,
    );

void main() {
  late PathwayGraph graph;
  setUpAll(() => graph = loadGraph());

  group('urgency bucketing', () {
    test('lands on the right side of every boundary', () {
      expect(at(now).urgency(now), DeadlineUrgency.thisWeek);
      expect(
        at(now.add(const Duration(days: 7))).urgency(now),
        DeadlineUrgency.thisWeek,
        reason: 'day 7 is still this week',
      );
      expect(
        at(now.add(const Duration(days: 8))).urgency(now),
        DeadlineUrgency.thisMonth,
      );
      expect(
        at(now.add(const Duration(days: 30))).urgency(now),
        DeadlineUrgency.thisMonth,
        reason: 'day 30 is still this month',
      );
      expect(
        at(now.add(const Duration(days: 31))).urgency(now),
        DeadlineUrgency.later,
      );
      expect(
        at(now.subtract(const Duration(days: 1))).urgency(now),
        DeadlineUrgency.overdue,
      );
    });

    test('a time of day never flips the bucket', () {
      // Late in the evening, with a deadline dated first thing the next
      // morning: still "tomorrow", not "today".
      final evening = DateTime(2026, 8, 15, 23, 30);
      final morning = DateTime(2026, 8, 16, 6, 0);
      expect(at(morning).daysRemaining(evening), 1);
      expect(at(morning).timing(evening), 'tomorrow');
    });

    test('no date is its own bucket, not overdue and not zero', () {
      final undated = at(null);
      expect(undated.daysRemaining(now), isNull);
      expect(undated.urgency(now), DeadlineUrgency.unknown);
      expect(undated.dateLabel, '—');
      expect(undated.timing(now), contains('No date yet'));
    });

    test('says the timing in words a person would use', () {
      expect(at(now.add(const Duration(days: 1))).timing(now), 'tomorrow');
      expect(at(now.add(const Duration(days: 3))).timing(now), 'in 3 days');
      expect(at(now.add(const Duration(days: 21))).timing(now), 'in 3 weeks');
      expect(at(now.add(const Duration(days: 90))).timing(now), 'in 3 months');
      expect(
        at(now.subtract(const Duration(days: 2))).timing(now),
        'overdue by 2 days',
      );
      expect(
        at(now.subtract(const Duration(days: 1))).timing(now),
        'overdue by 1 day',
      );
    });
  });

  group('approximate dates', () {
    test('never claim a day, in either direction', () {
      final future = at(DateTime(2027, 3, 1), approximate: true);
      expect(future.timing(now), contains('sometime in March 2027'));
      expect(future.timing(now), contains('not sure of the exact date'));
      expect(future.dateLabel, 'March 2027');

      // The anchor is months past, but an inferred window must never be
      // reported as "overdue by 167 days".
      final past = at(DateTime(2026, 3, 1), approximate: true);
      expect(past.urgency(now), DeadlineUrgency.overdue);
      expect(past.timing(now), isNot(contains('overdue by')));
      expect(past.timing(now), contains('may already have passed'));
    });

    test('an exact date does get a day stamp', () {
      expect(at(DateTime(2026, 9, 12)).dateLabel, '12 Sep 2026');
    });
  });

  group('json', () {
    test('round-trips every field, undated ones included', () {
      const before = Deadline(
        id: 'derived.status_expiry',
        title: 'Your current status runs out',
        description: 'because you said so',
        isApproximate: true,
        approximateLabel: 'March 2027',
        severity: DeadlineSeverity.critical,
        source: DeadlineSource.derivedFromPathway,
        relatedNodeId: 'student.stem_opt',
        dismissible: false,
        consequence: 'falling out of status',
        nextAction: 'check your I-94',
      );
      final dated = before.copyWith(dueDate: DateTime(2027, 3, 1));

      for (final original in [before, dated]) {
        final after = Deadline.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
        );
        expect(after.id, original.id);
        expect(after.title, original.title);
        expect(after.dueDate, original.dueDate);
        expect(after.isApproximate, original.isApproximate);
        expect(after.approximateLabel, original.approximateLabel);
        expect(after.severity, original.severity);
        expect(after.source, original.source);
        expect(after.relatedNodeId, original.relatedNodeId);
        expect(after.dismissible, original.dismissible);
        expect(after.consequence, original.consequence);
        expect(after.nextAction, original.nextAction);
      }
    });

    test('a corrupt date reads as "no date", never as today', () {
      final d = Deadline.fromJson({'id': 'a', 'due_date': 'not a date'});
      expect(d.dueDate, isNull);
      expect(d.urgency(now), DeadlineUrgency.unknown);
    });
  });

  group('sort order', () {
    test('nearest bucket first, undated last, ties broken by weight', () {
      final overdue = at(
        now.subtract(const Duration(days: 3)),
        id: 'overdue',
      );
      final week = at(now.add(const Duration(days: 2)), id: 'week');
      final month = at(now.add(const Duration(days: 20)), id: 'month');
      final later = at(now.add(const Duration(days: 200)), id: 'later');
      final undated = at(null, id: 'undated');

      final sorted = Deadline.sorted([
        undated,
        later,
        week,
        overdue,
        month,
      ], now);
      expect(sorted.map((d) => d.id).toList(), [
        'overdue',
        'week',
        'month',
        'later',
        'undated',
      ]);
    });

    test('same day: the heavier item wins', () {
      final due = now.add(const Duration(days: 4));
      final routine = Deadline(
        id: 'routine',
        title: 'a',
        description: '',
        dueDate: due,
        severity: DeadlineSeverity.routine,
      );
      final critical = Deadline(
        id: 'critical',
        title: 'b',
        description: '',
        dueDate: due,
        severity: DeadlineSeverity.critical,
      );
      expect(
        Deadline.sorted([routine, critical], now).first.id,
        'critical',
      );
    });
  });

  group('derivation from a situation', () {
    test('a month and a year become an approximate anchor, never a hard day', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(
          statusText: 'I am on OPT',
          statusChip: 'F-1 student',
          changeYear: 2027,
          changeMonth: 3,
        ),
        graph: graph,
        now: now,
      );

      final expiry = items.firstWhere((d) => d.id == 'derived.status_expiry');
      expect(expiry.dueDate, DateTime(2027, 3, 1));
      expect(expiry.isApproximate, isTrue);
      expect(expiry.approximateLabel, 'March 2027');
      expect(expiry.severity, DeadlineSeverity.critical);
      expect(expiry.source, DeadlineSource.derivedFromStatus);
      expect(
        expiry.dismissible,
        isFalse,
        reason: 'the anchor the rest of the list hangs off is not dismissible',
      );
      expect(expiry.consequence, isNotEmpty);
      expect(expiry.nextAction, isNotEmpty);

      // Six months of lead time, still in the future, so it is offered.
      final lead = items.firstWhere((d) => d.id == 'derived.prepare_lead_time');
      expect(lead.dueDate, DateTime(2026, 9, 1));
      expect(lead.isApproximate, isTrue);
      expect(
        lead.description.toLowerCase(),
        contains('typically'),
        reason: 'a heuristic must read as one',
      );
    });

    test('a year on its own anchors to the start of it and says so', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(statusText: 'H-1B', changeYear: 2028),
        now: now,
      );
      final expiry = items.firstWhere((d) => d.id == 'derived.status_expiry');
      expect(expiry.dueDate, DateTime(2028, 1, 1));
      expect(expiry.approximateLabel, '2028');
      expect(expiry.timing(now), contains('sometime in 2028'));
    });

    test('"I don\'t know" produces a task, not an invented date', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(
          statusText: 'I am on a student visa',
          dateUnknown: true,
        ),
        now: now,
      );

      expect(
        items.any((d) => d.id == 'derived.status_expiry'),
        isFalse,
        reason: 'nothing may manufacture a date out of "I do not know"',
      );
      final ask = items.firstWhere((d) => d.id == 'derived.expiry_unknown');
      expect(ask.dueDate, isNull);
      expect(ask.urgency(now), DeadlineUrgency.unknown);
      expect(ask.nextAction, contains('i94'));
    });

    test('no situation at all derives nothing rather than a sample list', () {
      expect(DeadlineService.derive(now: now), isEmpty);
      expect(
        DeadlineService.derive(situation: const VisaSituation(), now: now),
        isEmpty,
      );
    });

    test('the grace period is flagged without a number being invented', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(statusText: 'F-1', changeYear: 2027),
        now: now,
      );
      final grace = items.firstWhere(
        (d) => d.id == 'derived.grace_period_check',
      );
      expect(
        grace.dueDate,
        isNull,
        reason: 'the pathway data does not quantify grace periods, so we do '
            'not either',
      );
      expect(grace.description, contains('depends on your status'));
    });

    test('the I-94 vs visa-stamp distinction is always surfaced', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(statusChip: 'H-1B'),
        now: now,
      );
      expect(items.any((d) => d.id == 'derived.i94_vs_visa'), isTrue);
    });
  });

  group('derivation from the pathway', () {
    CaseProfile profile({String? current, String? goal}) => CaseProfile(
      currentNodeId: current,
      goalNodeId: goal,
      updatedAt: now,
    );

    test('H-1B registration points at the next March, quoting the data', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(statusChip: 'F-1 student'),
        profile: profile(current: 'student.stem_opt', goal: 'temp_worker.h1b'),
        graph: graph,
        now: now,
      );

      // 15 August is past this year's window, so it must point at 2027 rather
      // than showing a permanently-overdue item.
      final reg = items.firstWhere(
        (d) => d.id.startsWith('derived.h1b_registration'),
      );
      expect(reg.dueDate, DateTime(2027, 3, 1));
      expect(reg.approximateLabel, 'March 2027');
      expect(reg.isApproximate, isTrue);
      expect(reg.title.toLowerCase(), contains('typically'));
      expect(reg.relatedNodeId, 'temp_worker.h1b');

      // Before mid-March it should be this year's window.
      final early = DeadlineService.derive(
        situation: const VisaSituation(statusChip: 'F-1 student'),
        profile: profile(current: 'student.stem_opt', goal: 'temp_worker.h1b'),
        graph: graph,
        now: DateTime(2026, 2, 1),
      ).firstWhere((d) => d.id.startsWith('derived.h1b_registration'));
      expect(early.dueDate, DateTime(2026, 3, 1));
    });

    test('no H-1B item for somebody with no route to it', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(statusChip: 'Green card'),
        profile: profile(current: 'post_lpr.lpr'),
        graph: graph,
        now: now,
      );
      expect(
        items.any((d) => d.id.startsWith('derived.h1b_registration')),
        isFalse,
      );
    });

    test('the OPT filing window is measured back from the program end', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(
          statusChip: 'F-1 student',
          changeYear: 2027,
          changeMonth: 5,
        ),
        profile: profile(current: 'student.f1'),
        graph: graph,
        now: now,
      );
      final opt = items.firstWhere((d) => d.id == 'derived.opt_window_opens');
      expect(opt.dueDate, DateTime(2027, 5, 1).subtract(const Duration(days: 90)));
      expect(opt.isApproximate, isTrue);
      expect(
        opt.description,
        contains('90 days before'),
        reason: 'the number is quoted from the pathway data, not made up here',
      );
    });

    test('ongoing obligations are folded into one item, not five', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(statusChip: 'H-1B'),
        profile: profile(current: 'temp_worker.h1b'),
        graph: graph,
        now: now,
      );
      final recurring = items.where(
        (d) => d.id == 'derived.recurring.temp_worker.h1b',
      );
      expect(recurring.length, 1);
      expect(recurring.single.dueDate, isNull);
      expect(recurring.single.description, contains('•'));
    });

    test('every derived item carries a consequence and a next action', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(
          statusChip: 'F-1 student',
          changeYear: 2027,
          changeMonth: 3,
        ),
        profile: profile(current: 'student.f1', goal: 'temp_worker.h1b'),
        graph: graph,
        now: now,
      );
      expect(items, isNotEmpty);
      for (final d in items) {
        expect(d.consequence, isNotEmpty, reason: d.id);
        expect(d.nextAction, isNotEmpty, reason: d.id);
        expect(d.title, isNotEmpty, reason: d.id);
      }
    });

    test('no graph means no pathway claims, and no crash', () {
      final items = DeadlineService.derive(
        situation: const VisaSituation(statusChip: 'F-1 student'),
        profile: profile(current: 'student.f1', goal: 'temp_worker.h1b'),
        now: now,
      );
      expect(items, isNotEmpty);
      expect(
        items.every((d) => d.source != DeadlineSource.derivedFromPathway),
        isTrue,
      );
    });
  });

  group('storage', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      DeadlineService.instance.forget();
      await AuthService.instance.continueAsDemoUser();
      await DeadlineService.instance.load();
    });

    tearDown(() async {
      DeadlineService.instance.forget();
      await AuthService.instance.signOut();
    });

    const situation = VisaSituation(
      statusChip: 'F-1 student',
      changeYear: 2027,
      changeMonth: 3,
    );

    List<Deadline> visible() => DeadlineService.instance.visible(
      situation: situation,
      now: now,
    );

    test('a dismissal survives a reload', () async {
      final service = DeadlineService.instance;
      expect(
        visible().any((d) => d.id == 'derived.i94_vs_visa'),
        isTrue,
      );

      await service.dismiss('derived.i94_vs_visa');
      expect(visible().any((d) => d.id == 'derived.i94_vs_visa'), isFalse);

      // Reload from storage the way a fresh page load would.
      service.forget();
      await service.load();
      expect(
        visible().any((d) => d.id == 'derived.i94_vs_visa'),
        isFalse,
        reason: 'a dismissal that does not persist is not a dismissal',
      );
      expect(
        service
            .hidden(situation: situation, now: now)
            .any((d) => d.id == 'derived.i94_vs_visa'),
        isTrue,
        reason: 'hidden, not destroyed — it has to be findable again',
      );

      await service.restore('derived.i94_vs_visa');
      expect(visible().any((d) => d.id == 'derived.i94_vs_visa'), isTrue);
    });

    test('a snooze hides it only until its date', () async {
      final service = DeadlineService.instance;
      await service.snooze('derived.i94_vs_visa', DateTime(2026, 9, 1));

      expect(service.isHidden('derived.i94_vs_visa', now), isTrue);
      expect(
        service.isHidden('derived.i94_vs_visa', DateTime(2026, 9, 1)),
        isFalse,
        reason: 'it comes back on the day, without being asked',
      );
    });

    test('a user-added deadline round-trips through storage', () async {
      final service = DeadlineService.instance;
      final mine = DeadlineService.compose(
        title: 'Renew my EAD',
        now: DateTime(2026, 8, 15, 9, 30),
        description: 'receipt number is on the I-797',
        dueDate: DateTime(2026, 11, 4),
        nextAction: 'book the appointment',
      );
      await service.add(mine);

      service.forget();
      await service.load();

      final restored = service.userAdded.single;
      expect(restored.id, mine.id);
      expect(restored.title, 'Renew my EAD');
      expect(restored.dueDate, DateTime(2026, 11, 4));
      expect(restored.source, DeadlineSource.userAdded);
      expect(restored.isApproximate, isFalse);
      expect(visible().map((d) => d.id), contains(mine.id));

      await service.remove(mine.id);
      expect(service.userAdded, isEmpty);
    });

    test('a user-added deadline may have no date at all', () async {
      final service = DeadlineService.instance;
      final vague = DeadlineService.compose(
        title: 'Ask my lawyer about the I-140',
        now: DateTime(2026, 8, 15, 10),
      );
      await service.add(vague);
      expect(vague.dueDate, isNull);
      expect(vague.urgency(now), DeadlineUrgency.unknown);

      // It is kept, and it sorts into the undated tail rather than jumping the
      // queue ahead of anything with a real date on it.
      final list = visible();
      final index = list.indexWhere((d) => d.id == vague.id);
      expect(index, greaterThanOrEqualTo(0));
      expect(
        list.take(index).every((d) => d.urgency(now) != DeadlineUrgency.unknown),
        isTrue,
        reason: 'undated items sort after every dated one',
      );
    });

    test('month-only user dates stay approximate', () async {
      final vague = DeadlineService.compose(
        title: 'Passport renewal',
        now: DateTime(2026, 8, 15, 11),
        dueDate: DateTime(2027, 2, 1),
        isApproximate: true,
      );
      expect(vague.isApproximate, isTrue);
      expect(vague.approximateLabel, 'February 2027');
      expect(vague.timing(now), contains('sometime in February 2027'));
    });
  });
}
