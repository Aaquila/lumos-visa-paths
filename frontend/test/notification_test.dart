import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/services/ics_export.dart';
import 'package:lumos/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything here is pure Dart on purpose — no browser, no widgets, no timers
/// that outlive a test. The parts of this feature that can be wrong in a way
/// nobody notices until a deadline is missed (line folding, escaping, day
/// arithmetic, catch-up) are exactly the parts that need to run in CI.

ScheduledReminder r({
  String id = 'x',
  String title = 'Renew your I-94',
  String body = 'body',
  required DateTime fireAt,
  DateTime? dueAt,
  String? group,
  String? deepLink,
  bool allDay = true,
  ReminderType type = ReminderType.deadline,
}) => ScheduledReminder(
  id: id,
  title: title,
  body: body,
  fireAt: fireAt,
  dueAt: dueAt,
  groupKey: group,
  deepLink: deepLink,
  allDay: allDay,
  type: type,
);

void main() {
  // ── ICS: structure ────────────────────────────────────────────────────────

  group('IcsExport structure', () {
    final now = DateTime.utc(2026, 8, 15, 9, 30);

    test('golden: an all-day deadline with one alarm', () {
      final ics = IcsExport.build([
        r(
          id: 'i94@7',
          group: 'i94',
          title: 'I-94 expires',
          body: 'Your I-94 expires in 7 days. There is time.',
          fireAt: DateTime(2026, 9, 23),
          dueAt: DateTime(2026, 9, 30),
          deepLink: '/dashboard',
        ),
      ], now: now);

      expect(
        ics,
        'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'PRODID:-//Lumos//Immigration Deadlines//EN\r\n'
        'CALSCALE:GREGORIAN\r\n'
        'METHOD:PUBLISH\r\n'
        'X-WR-CALNAME:Lumos immigration deadlines\r\n'
        'X-WR-TIMEZONE:UTC\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:lumos-i94-20260930@lumos.app\r\n'
        'DTSTAMP:20260815T093000Z\r\n'
        'DTSTART;VALUE=DATE:20260930\r\n'
        'DTEND;VALUE=DATE:20261001\r\n'
        'SUMMARY:I-94 expires\r\n'
        'DESCRIPTION:Your I-94 expires in 7 days. There is time.\\n\\nOpen in Lumos: /\r\n'
        ' dashboard\\n\\nLumos supports\\, and does not replace\\, a licensed immigratio\r\n'
        ' n attorney.\r\n'
        'STATUS:CONFIRMED\r\n'
        'TRANSP:TRANSPARENT\r\n'
        'CATEGORIES:Filing deadlines\r\n'
        'URL:/dashboard\r\n'
        'BEGIN:VALARM\r\n'
        'ACTION:DISPLAY\r\n'
        'TRIGGER:-P7D\r\n'
        'DESCRIPTION:Your I-94 expires in 7 days. There is time.\r\n'
        'END:VALARM\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n',
      );
    });

    test('every line ends CRLF, including the last', () {
      final ics = IcsExport.build([
        r(fireAt: DateTime(2026, 9, 1), dueAt: DateTime(2026, 9, 8)),
      ], now: now);

      expect(ics.endsWith('\r\n'), isTrue);
      // No bare LF anywhere: every \n must be preceded by \r.
      for (var i = 0; i < ics.length; i++) {
        if (ics[i] == '\n') {
          expect(i > 0 && ics[i - 1] == '\r', isTrue, reason: 'bare LF at $i');
        }
      }
      expect(ics.contains('\r\r'), isFalse);
    });

    test('all-day DTEND is the following day, non-inclusive', () {
      final ics = IcsExport.build([
        r(fireAt: DateTime(2026, 12, 24), dueAt: DateTime(2026, 12, 31)),
      ], now: now);
      expect(ics, contains('DTSTART;VALUE=DATE:20261231\r\n'));
      expect(ics, contains('DTEND;VALUE=DATE:20270101\r\n'));
      expect(ics, isNot(contains('DTSTART:2026')));
    });

    test('timed events use UTC DATE-TIME with a default duration', () {
      final ics = IcsExport.build([
        r(
          allDay: false,
          fireAt: DateTime.utc(2026, 5, 1, 8),
          dueAt: DateTime.utc(2026, 5, 4, 9, 40),
          type: ReminderType.appointment,
        ),
      ], now: now);
      expect(ics, contains('DTSTART:20260504T094000Z\r\n'));
      expect(ics, contains('DTEND:20260504T104000Z\r\n'));
      expect(ics, isNot(contains('VALUE=DATE:')));
    });

    test('DTSTAMP and UID are present on every event', () {
      final ics = IcsExport.build([
        r(id: 'a', group: 'a', fireAt: DateTime(2026, 1, 1)),
        r(id: 'b', group: 'b', fireAt: DateTime(2026, 2, 1)),
      ], now: now);
      expect('DTSTAMP:'.allMatches(ics).length, 2);
      expect('UID:'.allMatches(ics).length, 2);
      expect('BEGIN:VEVENT'.allMatches(ics).length, 2);
    });

    test('one date shared by several lead times is one event, many alarms', () {
      final due = DateTime(2026, 10, 1);
      final ics = IcsExport.build([
        r(id: 'k@30', group: 'k', fireAt: due.subtract(const Duration(days: 30)), dueAt: due),
        r(id: 'k@7', group: 'k', fireAt: due.subtract(const Duration(days: 7)), dueAt: due),
        r(id: 'k@1', group: 'k', fireAt: due.subtract(const Duration(days: 1)), dueAt: due),
      ], now: now);

      expect('BEGIN:VEVENT'.allMatches(ics).length, 1);
      expect('BEGIN:VALARM'.allMatches(ics).length, 3);
      // Longest lead first — the calm one leads.
      expect(
        ics.indexOf('TRIGGER:-P30D'),
        lessThan(ics.indexOf('TRIGGER:-P1D')),
      );
    });

    test('identical triggers collapse rather than ringing twice', () {
      final due = DateTime(2026, 10, 1);
      final ics = IcsExport.build([
        r(id: 'k@7a', group: 'k', fireAt: due.subtract(const Duration(days: 7)), dueAt: due),
        r(id: 'k@7b', group: 'k', fireAt: due.subtract(const Duration(days: 7)), dueAt: due),
      ], now: now);
      expect('BEGIN:VALARM'.allMatches(ics).length, 1);
    });

    test('an empty export is still a valid, empty calendar', () {
      final ics = IcsExport.build(const [], now: now);
      expect(ics, startsWith('BEGIN:VCALENDAR\r\n'));
      expect(ics, endsWith('END:VCALENDAR\r\n'));
      expect(ics, isNot(contains('VEVENT')));
      expect(IcsExport.download(const []), isFalse);
    });
  });

  // ── ICS: escaping ─────────────────────────────────────────────────────────

  group('IcsExport escaping (RFC 5545 §3.3.11)', () {
    test('commas, semicolons, backslashes and newlines', () {
      expect(IcsExport.escapeText('a,b'), r'a\,b');
      expect(IcsExport.escapeText('a;b'), r'a\;b');
      expect(IcsExport.escapeText(r'a\b'), r'a\\b');
      expect(IcsExport.escapeText('a\nb'), r'a\nb');
      expect(IcsExport.escapeText('a\r\nb'), r'a\nb');
      expect(IcsExport.escapeText('a\rb'), r'a\nb');
    });

    test('backslash is escaped first, so escapes are not double-escaped', () {
      // Naive ordering turns this into a\\\,b — a literal backslash then a
      // literal comma, which is not what was written.
      expect(IcsExport.escapeText(r'a\,b'), r'a\\\,b');
    });

    test('a hostile SUMMARY cannot inject an iCalendar property', () {
      final ics = IcsExport.build([
        r(
          title: 'Fee: \$410; due Oct 1, 2026\nEND:VEVENT\nBEGIN:VEVENT',
          fireAt: DateTime(2026, 10, 1),
        ),
      ], now: DateTime.utc(2026, 8, 15));

      // What matters is that no *line* is a property delimiter: the escaped
      // newline keeps the injected text inside the SUMMARY value, where the
      // literal characters "END:VEVENT" are harmless content.
      final lines = ics.split('\r\n');
      expect(lines.where((l) => l == 'BEGIN:VEVENT').length, 1);
      expect(lines.where((l) => l == 'END:VEVENT').length, 1);
      expect(
        ics.replaceAll('\r\n ', ''),
        contains(r'SUMMARY:Fee: $410\; due Oct 1\, 2026\nEND:VEVENT'),
      );
    });
  });

  // ── ICS: folding ──────────────────────────────────────────────────────────

  group('IcsExport line folding (RFC 5545 §3.1)', () {
    test('short lines are untouched', () {
      expect(IcsExport.foldLine('SUMMARY:short'), 'SUMMARY:short');
      final exactly75 = 'X' * 75;
      expect(IcsExport.foldLine(exactly75), exactly75);
    });

    test('a 76-octet line folds once', () {
      final folded = IcsExport.foldLine('X' * 76);
      expect(folded, '${'X' * 75}\r\n X');
    });

    test('no output line exceeds 75 octets, continuation space included', () {
      final folded = IcsExport.foldLine('SUMMARY:${'deadline ' * 40}');
      for (final line in folded.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
      // Every continuation begins with the fold space. A second space is
      // legitimate — it is content that happened to land on the split point,
      // and unfolding strips only the first.
      for (final line in folded.split('\r\n').skip(1)) {
        expect(line.startsWith(' '), isTrue);
      }
    });

    test('unfolding restores the original text', () {
      final original = 'DESCRIPTION:${'a long sentence about paperwork. ' * 8}';
      final unfolded = IcsExport.foldLine(original).replaceAll('\r\n ', '');
      expect(unfolded, original);
    });

    test('a fold never splits a multi-byte character', () {
      // Devanagari: 3 bytes per character, so a byte-count fold lands
      // mid-codepoint unless the split point backs off.
      final name = 'SUMMARY:${'नमस्ते' * 20}';
      final folded = IcsExport.foldLine(name);

      expect(folded.contains('�'), isFalse, reason: 'mojibake');
      expect(folded.replaceAll('\r\n ', ''), name);
      for (final line in folded.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
    });

    test('folding is measured in octets, not characters', () {
      // 40 × 2-byte characters = 80 octets but only 40 characters: a
      // character-counted implementation would not fold this at all.
      final line = 'é' * 40;
      expect(line.length, 40);
      expect(utf8.encode(line).length, 80);
      expect(IcsExport.foldLine(line), contains('\r\n '));
    });

    test('a folded body still round-trips through a full calendar', () {
      final ics = IcsExport.build([
        r(
          title: 'Renew ${'x' * 200}',
          fireAt: DateTime(2026, 3, 1),
        ),
      ], now: DateTime.utc(2026, 1, 1));
      for (final line in ics.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
      expect(ics.replaceAll('\r\n ', ''), contains('SUMMARY:Renew ${'x' * 200}'));
    });
  });

  // ── ICS: triggers ─────────────────────────────────────────────────────────

  group('IcsExport.formatTrigger', () {
    test('whole days', () {
      expect(IcsExport.formatTrigger(const Duration(days: 30)), '-P30D');
      expect(IcsExport.formatTrigger(const Duration(days: 1)), '-P1D');
    });

    test('mixed components', () {
      expect(
        IcsExport.formatTrigger(const Duration(days: 1, hours: 2, minutes: 3)),
        '-P1DT2H3M',
      );
      expect(IcsExport.formatTrigger(const Duration(hours: 9)), '-PT9H');
      expect(IcsExport.formatTrigger(const Duration(minutes: 15)), '-PT15M');
      expect(IcsExport.formatTrigger(const Duration(seconds: 30)), '-PT30S');
    });

    test('zero and negative lead times mean "at the event", not "-PT0S"', () {
      expect(IcsExport.formatTrigger(Duration.zero), 'PT0S');
      expect(IcsExport.formatTrigger(const Duration(days: -3)), 'PT0S');
    });
  });

  // ── Lead-time computation ─────────────────────────────────────────────────

  group('ReminderPlanner.plan', () {
    final now = DateTime(2026, 8, 15, 10);
    final due = DateTime(2026, 12, 1);

    test('default lead times produce 30/7/1, soonest first', () {
      final plan = ReminderPlanner.plan(
        groupKey: 'i485',
        what: 'I-485 filing window closes',
        dueAt: due,
        now: now,
      );

      expect(plan.length, 3);
      expect(plan.map((p) => p.fireAt), [
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 24),
        DateTime(2026, 11, 30),
      ]);
      expect(plan.every((p) => p.group == 'i485'), isTrue);
      expect(plan.every((p) => p.dueAt == due), isTrue);
      expect(plan.map((p) => p.id), ['i485@30', 'i485@7', 'i485@1']);
    });

    test('lead times already in the past are dropped', () {
      final soon = now.add(const Duration(days: 3));
      final plan = ReminderPlanner.plan(
        groupKey: 'g',
        what: 'thing',
        dueAt: soon,
        now: now,
      );
      // Only the 1-day nudge is still ahead of us.
      expect(plan.length, 1);
      expect(plan.single.id, 'g@1');
    });

    test('includePast keeps them, for a schedule being rebuilt', () {
      final soon = now.add(const Duration(days: 3));
      final plan = ReminderPlanner.plan(
        groupKey: 'g',
        what: 'thing',
        dueAt: soon,
        now: now,
        includePast: true,
      );
      expect(plan.length, 3);
    });

    test('muted and snoozed both plan nothing', () {
      expect(
        ReminderPlanner.plan(
          groupKey: 'g',
          what: 'thing',
          dueAt: due,
          now: now,
          prefs: const NotificationPreferences(muted: true),
        ),
        isEmpty,
      );
      expect(
        ReminderPlanner.plan(
          groupKey: 'g',
          what: 'thing',
          dueAt: due,
          now: now,
          prefs: NotificationPreferences(
            quietUntil: now.add(const Duration(days: 2)),
          ),
        ),
        isEmpty,
      );
    });

    test('a disabled type plans nothing', () {
      expect(
        ReminderPlanner.plan(
          groupKey: 'g',
          what: 'thing',
          dueAt: due,
          now: now,
          type: ReminderType.policyUpdate,
          prefs: const NotificationPreferences(
            enabledTypes: {ReminderType.deadline},
          ),
        ),
        isEmpty,
      );
    });

    test('custom lead times are honoured, sorted and de-duplicated', () {
      final plan = ReminderPlanner.plan(
        groupKey: 'g',
        what: 'thing',
        dueAt: due,
        now: now,
        prefs: const NotificationPreferences(leadDays: [7, 90, 7, 0, -5, 900]),
      );
      expect(plan.map((p) => p.id), ['g@90', 'g@7']);
    });

    test('no lead times at all still yields the day-before safety net', () {
      final plan = ReminderPlanner.plan(
        groupKey: 'g',
        what: 'thing',
        dueAt: due,
        now: now,
        prefs: const NotificationPreferences(leadDays: []),
      );
      expect(plan.map((p) => p.id), ['g@1']);
    });

    test('copy is calm and carries no guilt', () {
      final plan = ReminderPlanner.plan(
        groupKey: 'g',
        what: 'Your I-94 expires',
        dueAt: due,
        now: now,
      );
      for (final p in plan) {
        expect(p.body, isNot(contains('!')));
        expect(p.body.toLowerCase(), isNot(contains('missed')));
        expect(p.body.toLowerCase(), isNot(contains('urgent')));
        expect(p.body.toLowerCase(), isNot(contains('failed')));
      }
      expect(plan.first.body, contains('There is time'));
    });
  });

  group('one reminder per day per deadline', () {
    test('two lead times landing on one day collapse to the earlier', () {
      final day = DateTime(2026, 5, 5);
      final collapsed = ReminderPlanner.onePerDayPerGroup([
        r(id: 'g@1', group: 'g', fireAt: day.add(const Duration(hours: 18))),
        r(id: 'g@30', group: 'g', fireAt: day.add(const Duration(hours: 9))),
      ]);
      expect(collapsed.length, 1);
      expect(collapsed.single.id, 'g@30');
    });

    test('different deadlines on the same day both survive', () {
      final day = DateTime(2026, 5, 5, 9);
      final collapsed = ReminderPlanner.onePerDayPerGroup([
        r(id: 'a@1', group: 'a', fireAt: day),
        r(id: 'b@1', group: 'b', fireAt: day),
      ]);
      expect(collapsed.length, 2);
    });

    test('the same deadline on different days both survive', () {
      final collapsed = ReminderPlanner.onePerDayPerGroup([
        r(id: 'a@1', group: 'a', fireAt: DateTime(2026, 5, 5)),
        r(id: 'a@2', group: 'a', fireAt: DateTime(2026, 5, 6)),
      ]);
      expect(collapsed.length, 2);
    });
  });

  group('ReminderPlanner.daysBetween', () {
    test('counts calendar days, not elapsed hours', () {
      expect(
        ReminderPlanner.daysBetween(
          DateTime(2026, 5, 5, 23, 30),
          DateTime(2026, 5, 6, 1),
        ),
        1,
      );
      expect(
        ReminderPlanner.daysBetween(
          DateTime(2026, 5, 5, 1),
          DateTime(2026, 5, 5, 23),
        ),
        0,
      );
    });
  });

  // ── Catch-up ──────────────────────────────────────────────────────────────

  group('ReminderPlanner.catchUp', () {
    final now = DateTime(2026, 8, 15, 9);
    final lastSeen = DateTime(2026, 8, 1, 9);

    test('surfaces what fired while the tab was closed', () {
      final missed = ReminderPlanner.catchUp(
        scheduled: [
          r(id: 'a', group: 'a', fireAt: DateTime(2026, 8, 5)),
          r(id: 'b', group: 'b', fireAt: DateTime(2026, 8, 10)),
        ],
        lastSeen: lastSeen,
        now: now,
      );
      expect(missed.map((m) => m.id), ['b', 'a']); // newest first
    });

    test('ignores reminders already delivered before we went away', () {
      final missed = ReminderPlanner.catchUp(
        scheduled: [r(id: 'old', fireAt: DateTime(2026, 7, 20))],
        lastSeen: lastSeen,
        now: now,
      );
      expect(missed, isEmpty);
    });

    test('ignores reminders still in the future', () {
      final missed = ReminderPlanner.catchUp(
        scheduled: [r(id: 'later', fireAt: DateTime(2026, 9, 1))],
        lastSeen: lastSeen,
        now: now,
      );
      expect(missed, isEmpty);
    });

    test('ignores anything older than the catch-up window', () {
      final missed = ReminderPlanner.catchUp(
        scheduled: [
          r(id: 'ancient', fireAt: now.subtract(const Duration(days: 40))),
        ],
        lastSeen: now.subtract(const Duration(days: 400)),
        now: now,
      );
      expect(missed, isEmpty);
    });

    test('is capped, so a month away is a summary not an avalanche', () {
      final missed = ReminderPlanner.catchUp(
        scheduled: [
          for (var i = 1; i <= 12; i++)
            r(
              id: 'g$i',
              group: 'g$i',
              fireAt: now.subtract(Duration(days: i)),
            ),
        ],
        lastSeen: now.subtract(const Duration(days: 20)),
        now: now,
      );
      expect(missed.length, 5);
      // The five most recent, newest first.
      expect(missed.map((m) => m.id), ['g1', 'g2', 'g3', 'g4', 'g5']);
    });

    test('still one per deadline per day after a long absence', () {
      final missed = ReminderPlanner.catchUp(
        scheduled: [
          r(id: 'g@30', group: 'g', fireAt: now.subtract(const Duration(days: 3))),
          r(
            id: 'g@7',
            group: 'g',
            fireAt: now.subtract(const Duration(days: 3, hours: 2)),
          ),
        ],
        lastSeen: now.subtract(const Duration(days: 10)),
        now: now,
      );
      expect(missed.length, 1);
    });

    test('a passed date is reported without blame', () {
      final missed = ReminderPlanner.catchUp(
        scheduled: [
          r(
            id: 'a',
            title: 'Your work permit renewal',
            fireAt: now.subtract(const Duration(days: 5)),
            dueAt: now.subtract(const Duration(days: 3)),
          ),
        ],
        lastSeen: now.subtract(const Duration(days: 10)),
        now: now,
      );
      final body = missed.single.body;
      expect(body, contains('This one has passed'));
      expect(body, contains('what to do now'));
      expect(body.toLowerCase(), isNot(contains('you missed')));
      expect(body, isNot(contains('!')));
    });

    test('a slipped nudge for a date still ahead stays in the future tense', () {
      final missed = ReminderPlanner.catchUp(
        scheduled: [
          r(
            id: 'a',
            title: 'Your I-485 window',
            fireAt: now.subtract(const Duration(days: 2)),
            dueAt: now.add(const Duration(days: 12)),
          ),
        ],
        lastSeen: now.subtract(const Duration(days: 5)),
        now: now,
      );
      expect(missed.single.body, contains('due in 12 days'));
      expect(missed.single.body, isNot(contains('passed')));
    });

    test('muting silences catch-up too', () {
      expect(
        ReminderPlanner.catchUp(
          scheduled: [r(id: 'a', fireAt: DateTime(2026, 8, 10))],
          lastSeen: lastSeen,
          now: now,
          prefs: const NotificationPreferences(muted: true),
        ),
        isEmpty,
      );
    });

    test('a type switched off while away is not caught up', () {
      expect(
        ReminderPlanner.catchUp(
          scheduled: [
            r(
              id: 'a',
              fireAt: DateTime(2026, 8, 10),
              type: ReminderType.policyUpdate,
            ),
          ],
          lastSeen: lastSeen,
          now: now,
          prefs: const NotificationPreferences(
            enabledTypes: {ReminderType.deadline},
          ),
        ),
        isEmpty,
      );
    });
  });

  // ── Preferences ───────────────────────────────────────────────────────────

  group('NotificationPreferences', () {
    test('defaults are generous and everything is on', () {
      const p = NotificationPreferences();
      expect(p.normalised, [30, 7, 1]);
      expect(p.muted, isFalse);
      expect(p.enabledTypes.length, ReminderType.values.length);
      expect(p.isSilenced(DateTime.now()), isFalse);
    });

    test('normalisation sorts, de-duplicates and rejects nonsense', () {
      const p = NotificationPreferences(leadDays: [7, 30, 7, 0, -1, 4000]);
      expect(p.normalised, [30, 7]);
    });

    test('a snooze silences until it expires, then stops on its own', () {
      final until = DateTime(2026, 8, 20);
      final p = NotificationPreferences(quietUntil: until);
      expect(p.isSilenced(DateTime(2026, 8, 19)), isTrue);
      expect(p.isSilenced(DateTime(2026, 8, 21)), isFalse);
    });

    test('json round-trip preserves every field', () {
      final original = NotificationPreferences(
        muted: true,
        leadDays: const [60, 14, 3],
        enabledTypes: const {ReminderType.deadline, ReminderType.appointment},
        quietUntil: DateTime(2026, 9, 1, 12, 30),
      );
      final restored = NotificationPreferences.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored, original);
      expect(restored.normalised, [60, 14, 3]);
      expect(restored.enabledTypes, original.enabledTypes);
      expect(restored.quietUntil, original.quietUntil);
    });

    test('corrupt or partial json degrades to defaults, never throws', () {
      expect(
        NotificationPreferences.fromJson({'leadDays': 'nonsense'}).normalised,
        [30, 7, 1],
      );
      expect(
        NotificationPreferences.fromJson({'leadDays': []}).normalised,
        [30, 7, 1],
      );
      expect(
        NotificationPreferences.fromJson(const {}).enabledTypes.length,
        ReminderType.values.length,
      );
      expect(
        NotificationPreferences.fromJson({'enabledTypes': ['bogus']})
            .enabledTypes,
        isEmpty,
      );
    });
  });

  group('preference persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips through SharedPreferences', () async {
      const store = NotificationPreferencesStore();
      final saved = NotificationPreferences(
        muted: false,
        leadDays: const [90, 30, 1],
        enabledTypes: const {ReminderType.document},
        quietUntil: DateTime(2026, 10, 5, 8),
      );

      await store.save(saved);
      expect(await store.load(), saved);
    });

    test('nothing stored yields defaults', () async {
      expect(
        await const NotificationPreferencesStore().load(),
        const NotificationPreferences(),
      );
    });

    test('unparseable stored value yields defaults instead of throwing', () async {
      SharedPreferences.setMockInitialValues({
        NotificationPreferencesStore.storageKey: 'not json at all',
      });
      expect(
        await const NotificationPreferencesStore().load(),
        const NotificationPreferences(),
      );
    });

    test('clearing removes the key', () async {
      const store = NotificationPreferencesStore();
      await store.save(const NotificationPreferences(muted: true));
      await store.clear();
      expect((await store.load()).muted, isFalse);
    });
  });

  // ── Reminder value type ───────────────────────────────────────────────────

  group('ScheduledReminder', () {
    test('json round-trip', () {
      final original = r(
        id: 'i94@7',
        group: 'i94',
        title: 'I-94 expires',
        body: 'body',
        fireAt: DateTime(2026, 9, 23, 9),
        dueAt: DateTime(2026, 9, 30),
        deepLink: '/dashboard?d=i94',
        type: ReminderType.document,
      );
      expect(
        ScheduledReminder.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
        ),
        original,
      );
    });

    test('group falls back to id, eventAt falls back to fireAt', () {
      final plain = r(id: 'solo', fireAt: DateTime(2026, 1, 1));
      expect(plain.group, 'solo');
      expect(plain.eventAt, plain.fireAt);
      expect(plain.leadTime, Duration.zero);
    });

    test('leadTime never goes negative', () {
      final late = r(
        fireAt: DateTime(2026, 2, 1),
        dueAt: DateTime(2026, 1, 1),
      );
      expect(late.leadTime, Duration.zero);
    });
  });

  // ── Service, against the no-op channel ────────────────────────────────────

  group('NotificationService', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('stores reminders even when nothing can be shown', () async {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);

      await svc.schedule(
        r(id: 'a', group: 'a', fireAt: DateTime(2027, 1, 1)),
      );
      await svc.schedule(
        r(id: 'b', group: 'b', fireAt: DateTime(2026, 1, 1)),
      );

      // Sorted soonest-first, and past reminders are still listed — the
      // calendar export and catch-up both need them.
      expect(svc.listScheduled().map((s) => s.id), ['b', 'a']);
      expect(svc.permissionStatus, NotificationPermission.unsupported);
      expect(svc.canNotify, isFalse);
      expect(await svc.showNow(title: 't', body: 'b'), isFalse);
    });

    test('closed-tab delivery is never claimed', () {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);
      expect(svc.canDeliverWhenClosed, isFalse);
    });

    test('scheduling the same id replaces rather than duplicates', () async {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);
      await svc.schedule(r(id: 'a', fireAt: DateTime(2027, 1, 1)));
      await svc.schedule(
        r(id: 'a', title: 'moved', fireAt: DateTime(2027, 2, 1)),
      );
      expect(svc.listScheduled().length, 1);
      expect(svc.listScheduled().single.title, 'moved');
    });

    test('replaceGroup drops the old dates for that deadline', () async {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);
      await svc.scheduleAll([
        r(id: 'g@30', group: 'g', fireAt: DateTime(2027, 1, 1)),
        r(id: 'g@7', group: 'g', fireAt: DateTime(2027, 1, 24)),
        r(id: 'other', group: 'other', fireAt: DateTime(2027, 3, 1)),
      ]);

      await svc.replaceGroup('g', [
        r(id: 'g@1', group: 'g', fireAt: DateTime(2027, 5, 1)),
      ]);

      expect(svc.listScheduled().map((s) => s.id).toSet(), {'other', 'g@1'});
    });

    test('cancel and cancelAll', () async {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);
      await svc.scheduleAll([
        r(id: 'a', group: 'a', fireAt: DateTime(2027, 1, 1)),
        r(id: 'b', group: 'b', fireAt: DateTime(2027, 2, 1)),
      ]);
      await svc.cancel('a');
      expect(svc.listScheduled().map((s) => s.id), ['b']);
      await svc.cancelAll();
      expect(svc.listScheduled(), isEmpty);
    });

    test('the schedule survives a restart and drives catch-up', () async {
      final now = DateTime.now();

      // Session one, five days ago: the app starts and books a reminder.
      final first = NotificationService.forTesting();
      addTearDown(first.dispose);
      await first.initialize(now: now.subtract(const Duration(days: 5)));
      await first.schedule(
        r(
          id: 'a',
          group: 'a',
          title: 'Your I-94 expires',
          // Its moment came and went with the tab shut.
          fireAt: now.subtract(const Duration(days: 1)),
          dueAt: now.add(const Duration(days: 6)),
        ),
      );

      // Session two: a fresh service reads the same storage.
      final second = NotificationService.forTesting();
      addTearDown(second.dispose);
      await second.initialize(now: now);

      expect(second.listScheduled().map((s) => s.id), ['a']);
      expect(second.missedWhileAway.map((m) => m.id), ['a']);

      second.acknowledgeCatchUp();
      expect(second.missedWhileAway, isEmpty);
    });

    test('preference changes persist and are visible immediately', () async {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);

      await svc.setMuted(true);
      expect(svc.preferences.muted, isTrue);
      expect(svc.canNotify, isFalse);

      await svc.setLeadDay(90, true);
      await svc.setLeadDay(1, false);
      expect(svc.preferences.normalised, [90, 30, 7]);

      await svc.setType(ReminderType.policyUpdate, false);
      expect(svc.preferences.isTypeEnabled(ReminderType.policyUpdate), isFalse);

      expect(
        await const NotificationPreferencesStore().load(),
        svc.preferences,
      );
    });

    test('unmuting is not destructive — the schedule is still there', () async {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);
      await svc.schedule(r(id: 'a', fireAt: DateTime(2027, 1, 1)));
      await svc.setMuted(true);
      expect(svc.listScheduled().length, 1);
      await svc.setMuted(false);
      expect(svc.listScheduled().length, 1);
      expect(svc.preferences.muted, isFalse);
    });

    test('a snooze expires on its own', () async {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);
      await svc.snooze(const Duration(days: 3));
      expect(svc.preferences.isSilenced(DateTime.now()), isTrue);
      expect(
        svc.preferences.isSilenced(DateTime.now().add(const Duration(days: 4))),
        isFalse,
      );
    });

    test('the whole schedule exports as one valid calendar', () async {
      final svc = NotificationService.forTesting();
      addTearDown(svc.dispose);
      final due = DateTime(2027, 4, 1);
      await svc.scheduleAll(
        ReminderPlanner.plan(
          groupKey: 'i765',
          what: 'Work permit renewal',
          dueAt: due,
          now: DateTime(2026, 8, 15),
        ),
      );

      final ics = IcsExport.build(
        svc.listScheduled(),
        now: DateTime.utc(2026, 8, 15),
      );
      expect('BEGIN:VEVENT'.allMatches(ics).length, 1);
      expect('BEGIN:VALARM'.allMatches(ics).length, 3);
      expect(ics, contains('SUMMARY:Work permit renewal'));
      expect(ics, endsWith('END:VCALENDAR\r\n'));
    });
  });
}
