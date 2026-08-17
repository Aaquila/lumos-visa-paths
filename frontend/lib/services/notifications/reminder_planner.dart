import 'notification_preferences.dart';
import 'scheduled_reminder.dart';

/// Turns "this thing is due on that date" into "tell them on these days",
/// and works out what to say about the ones we slept through.
///
/// Every method here is pure — no clock, no storage, no browser. That is on
/// purpose: this is the part that is easy to get subtly wrong (off-by-one days,
/// double-notifying, notifying about something two years ago) and it is the
/// part that has to be testable without a browser.
class ReminderPlanner {
  const ReminderPlanner._();

  /// How far back a missed reminder is still worth mentioning.
  ///
  /// Past this, surfacing it is noise about something the person has long since
  /// dealt with or long since lost — either way a notification does not help.
  static const catchUpWindow = Duration(days: 30);

  /// The nudges for one due date.
  ///
  /// One [ScheduledReminder] per enabled lead time, all sharing [groupKey] so
  /// the once-a-day rule can see they are the same underlying thing. Reminders
  /// whose moment is already behind [now] are dropped here — catching those up
  /// is [catchUp]'s job and has different wording.
  ///
  /// [dueAt] is taken as-is: if the caller hands us a local midnight for an
  /// all-day filing deadline, the nudges land at the same local clock time.
  static List<ScheduledReminder> plan({
    required String groupKey,
    required String what,
    required DateTime dueAt,
    required DateTime now,
    NotificationPreferences prefs = const NotificationPreferences(),
    ReminderType type = ReminderType.deadline,
    String? deepLink,
    bool allDay = true,
    bool includePast = false,
  }) {
    if (prefs.isSilenced(now) || !prefs.isTypeEnabled(type)) return const [];

    final out = <ScheduledReminder>[];
    for (final lead in prefs.normalised) {
      final fireAt = minusDays(dueAt, lead);
      if (!includePast && !fireAt.isAfter(now)) continue;
      out.add(
        ScheduledReminder(
          id: '$groupKey@$lead',
          groupKey: groupKey,
          title: what,
          body: ReminderCopy.ahead(what, lead),
          fireAt: fireAt,
          dueAt: dueAt,
          deepLink: deepLink,
          type: type,
          allDay: allDay,
        ),
      );
    }
    out.sort((a, b) => a.fireAt.compareTo(b.fireAt));
    return _onePerDayPerGroup(out);
  }

  /// The rule: never more than one notification per day per underlying thing.
  ///
  /// Two lead times can collide on the same calendar day (a 7-day and a 1-day
  /// nudge for two deadlines a week apart, a person who picked 3 and 1 on a
  /// short fuse). When they do, the *earlier* one in the day survives — it is
  /// the one with more runway, and it is the calmer message.
  static List<ScheduledReminder> onePerDayPerGroup(
    List<ScheduledReminder> reminders,
  ) => _onePerDayPerGroup([...reminders]..sort(_byFireAt));

  static List<ScheduledReminder> _onePerDayPerGroup(
    List<ScheduledReminder> sorted,
  ) {
    final seen = <String>{};
    final out = <ScheduledReminder>[];
    for (final r in sorted) {
      final slot = '${r.group}|${dayKey(r.fireAt)}';
      if (seen.add(slot)) out.add(r);
    }
    return out;
  }

  static int _byFireAt(ScheduledReminder a, ScheduledReminder b) =>
      a.fireAt.compareTo(b.fireAt);

  /// [days] calendar days earlier, at the same wall-clock time.
  ///
  /// Not `subtract(Duration(days: n))`, which subtracts 24-hour blocks: across
  /// a daylight-saving boundary that lands an hour off, so a reminder set for
  /// 09:00 arrives at 08:00 or 10:00 and the "30 days before" nudge is not
  /// actually 30 calendar days before. `DateTime`'s constructor normalises
  /// out-of-range day numbers (day 0 is the last day of the previous month),
  /// so month and year boundaries fall out for free.
  static DateTime minusDays(DateTime t, int days) {
    if (t.isUtc) {
      return DateTime.utc(
        t.year,
        t.month,
        t.day - days,
        t.hour,
        t.minute,
        t.second,
        t.millisecond,
        t.microsecond,
      );
    }
    return DateTime(
      t.year,
      t.month,
      t.day - days,
      t.hour,
      t.minute,
      t.second,
      t.millisecond,
      t.microsecond,
    );
  }

  /// `2026-08-15` — the calendar day a moment falls on, in its own zone.
  static String dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// Whole days between two moments, counted by calendar day rather than by
  /// elapsed hours — so 23:00 today to 01:00 tomorrow is 1 day, not 0.
  static int daysBetween(DateTime from, DateTime to) {
    final a = DateTime(from.year, from.month, from.day);
    final b = DateTime(to.year, to.month, to.day);
    return b.difference(a).inDays;
  }

  /// "While you were away."
  ///
  /// Given everything that was on the schedule and the moment we last had the
  /// tab open, returns the ones whose time passed unseen — re-worded for the
  /// past tense, still one per group per day, still capped.
  ///
  /// Three things are deliberately excluded:
  ///  * anything older than [catchUpWindow] — stale alarm helps nobody;
  ///  * anything that already fired before [lastSeen] — it was delivered;
  ///  * anything for a type the user has since switched off.
  ///
  /// Results are newest-first, so if the cap bites, what survives is the most
  /// recent state of each thing rather than a month-old first draft.
  static List<ScheduledReminder> catchUp({
    required List<ScheduledReminder> scheduled,
    required DateTime lastSeen,
    required DateTime now,
    NotificationPreferences prefs = const NotificationPreferences(),
    int maxItems = 5,
  }) {
    if (prefs.isSilenced(now)) return const [];

    final horizon = now.subtract(catchUpWindow);
    final missed = scheduled.where((r) {
      if (!prefs.isTypeEnabled(r.type)) return false;
      if (r.fireAt.isAfter(now)) return false; // still in the future
      if (!r.fireAt.isAfter(lastSeen)) return false; // already delivered
      if (r.fireAt.isBefore(horizon)) return false; // too old to be useful
      return true;
    }).toList()..sort(_byFireAt);

    // Collapse to one per group per day first, then keep the newest few.
    final collapsed = _onePerDayPerGroup(missed).reversed.toList();

    return collapsed
        .take(maxItems)
        .map((r) => r.copyWith(body: _pastBody(r, now)))
        .toList();
  }

  static String _pastBody(ScheduledReminder r, DateTime now) {
    final due = r.eventAt;
    if (due.isAfter(now)) {
      // The nudge slipped but the deadline itself has not — the calm case.
      return ReminderCopy.ahead(r.title, daysBetween(now, due));
    }
    return ReminderCopy.past(r.title, daysBetween(due, now));
  }

  /// Everything still ahead of [now], soonest first — what a service restores
  /// timers for on start-up.
  static List<ScheduledReminder> upcoming(
    List<ScheduledReminder> scheduled,
    DateTime now,
  ) =>
      (scheduled.where((r) => r.fireAt.isAfter(now)).toList()..sort(_byFireAt));

  /// Anything whose moment is far enough past that keeping it costs more than
  /// it is worth. Used to stop the persisted schedule growing forever.
  static bool isExpired(ScheduledReminder r, DateTime now) =>
      r.fireAt.isBefore(now.subtract(catchUpWindow));
}
