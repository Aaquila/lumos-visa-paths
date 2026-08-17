/// A dated thing the person needs to know about, in their own timeline.
///
/// Three rules shaped this model, and all three are product rules rather than
/// engineering taste:
///
///  1. **No invented dates.** Immigration deadlines are real legal dates and a
///     confidently-wrong one is worse than none. A [Deadline] may therefore have
///     no [dueDate] at all ([DeadlineUrgency.unknown]) or an
///     [isApproximate] one carrying an [approximateLabel] like "March 2026" —
///     because "some time in March" is genuinely what somebody told us, and
///     rounding that to the 1st and printing it as a hard date would be a lie.
///  2. **`now` is injected everywhere.** Nothing here calls `DateTime.now()`.
///     Every time-dependent read takes the clock as an argument, so the whole
///     model is pure and testable at boundaries.
///  3. **Every item carries a consequence and a next action.** A deadline the
///     reader cannot act on is just anxiety with a date on it.
library;

import 'package:flutter/foundation.dart';

/// How close a deadline is, once measured against a clock.
///
/// Deliberately coarse. Overwhelmed readers do not need a countdown to the
/// hour; they need to know whether this is a today problem or a someday problem.
enum DeadlineUrgency {
  overdue,
  thisWeek,
  thisMonth,
  later,

  /// We know the thing matters but not when it lands — the honest bucket for
  /// "you told me you do not know your expiry date".
  unknown;

  /// Sort weight. Overdue first, unknown last: an undated item is real but it
  /// cannot out-rank something with a date on it this week.
  int get rank => switch (this) {
    DeadlineUrgency.overdue => 0,
    DeadlineUrgency.thisWeek => 1,
    DeadlineUrgency.thisMonth => 2,
    DeadlineUrgency.later => 3,
    DeadlineUrgency.unknown => 4,
  };

  /// Short heading for a group of these. Plain words, no alarm language.
  String get label => switch (this) {
    DeadlineUrgency.overdue => 'Past its date',
    DeadlineUrgency.thisWeek => 'This week',
    DeadlineUrgency.thisMonth => 'This month',
    DeadlineUrgency.later => 'Later on',
    DeadlineUrgency.unknown => 'No date yet',
  };
}

/// How much weight the *item* carries, independent of how near it is.
///
/// Separate from [DeadlineUrgency] on purpose: "your status runs out" is a big
/// deal in June and still a big deal next February, whereas "update your
/// address" is small even when it is due tomorrow.
enum DeadlineSeverity {
  /// Status, work authorisation, or the right to stay depends on it.
  critical,

  /// Materially affects the plan, but missing it is recoverable.
  important,

  /// Housekeeping and ongoing obligations.
  routine;

  int get rank => switch (this) {
    DeadlineSeverity.critical => 0,
    DeadlineSeverity.important => 1,
    DeadlineSeverity.routine => 2,
  };

  String get wire => name;

  static DeadlineSeverity parse(String? raw) => switch (raw) {
    'critical' => DeadlineSeverity.critical,
    'routine' => DeadlineSeverity.routine,
    _ => DeadlineSeverity.important,
  };
}

/// Where a deadline came from — shown to the reader, because a date they typed
/// and a date we inferred deserve different amounts of trust.
enum DeadlineSource {
  /// Inferred from the status and change-date given in onboarding.
  derivedFromStatus,

  /// Inferred from the confirmed pathway and the generic pathway graph.
  derivedFromPathway,

  /// The person added it themselves.
  userAdded;

  String get wire => switch (this) {
    DeadlineSource.derivedFromStatus => 'derived-from-status',
    DeadlineSource.derivedFromPathway => 'derived-from-pathway',
    DeadlineSource.userAdded => 'user-added',
  };

  static DeadlineSource parse(String? raw) => switch (raw) {
    'derived-from-status' => DeadlineSource.derivedFromStatus,
    'derived-from-pathway' => DeadlineSource.derivedFromPathway,
    _ => DeadlineSource.userAdded,
  };

  String get label => switch (this) {
    DeadlineSource.derivedFromStatus =>
      'From what you told me about your status',
    DeadlineSource.derivedFromPathway => 'From the pathway you confirmed',
    DeadlineSource.userAdded => 'You added this',
  };

  bool get isDerived => this != DeadlineSource.userAdded;
}

@immutable
class Deadline {
  const Deadline({
    required this.id,
    required this.title,
    required this.description,
    this.dueDate,
    this.isApproximate = false,
    this.approximateLabel,
    this.severity = DeadlineSeverity.important,
    this.source = DeadlineSource.userAdded,
    this.relatedNodeId,
    this.dismissible = true,
    this.consequence = '',
    this.nextAction = '',
  });

  /// Stable across derivations, so dismissing something makes it stay dismissed.
  /// Derived ids are `derived.*`; user ones are `user.<millis>`.
  final String id;

  /// One short line, in the reader's language rather than form numbers.
  final String title;

  /// Plain English: what this actually is and why it is on the list.
  final String description;

  /// When it lands. **Null is a real, supported state** — it means "this
  /// matters and we do not know when", which is different from "no deadline".
  ///
  /// When [isApproximate] is true this is an *anchor*, not a claim: it is the
  /// earliest day the window could plausibly start, because for a deadline the
  /// safe direction to be wrong in is early.
  final DateTime? dueDate;

  /// True when only a month, or only a year, is actually known.
  final bool isApproximate;

  /// How to say the approximate window out loud — "March 2026", "2027".
  final String? approximateLabel;

  final DeadlineSeverity severity;
  final DeadlineSource source;

  /// The pathway-graph node this hangs off, when there is one.
  final String? relatedNodeId;

  /// False for the one or two anchors the whole list is measured from — losing
  /// those to a stray tap would quietly break the tracker.
  final bool dismissible;

  /// "What happens if you miss this", hedged and non-catastrophising.
  final String consequence;

  /// Exactly one concrete thing to do next.
  final String nextAction;

  /// The line that must accompany any surface showing these.
  static const disclaimer =
      'This is information, not legal advice, and the dates here are worked out '
      'from what you told me. Confirm every date against your own paperwork — '
      'your I-94, your I-797 approval notice, or your EAD card — and talk to an '
      'immigration lawyer before you rely on any of it.';

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static const _monthsShort = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// Whole days from [now] to [dueDate], counted date-to-date so that a clock
  /// time never flips the answer. Negative means the date has passed. Null when
  /// there is no date — callers must handle that rather than defaulting to 0.
  int? daysRemaining(DateTime now) {
    final due = dueDate;
    if (due == null) return null;
    final a = DateTime(now.year, now.month, now.day);
    final b = DateTime(due.year, due.month, due.day);
    return b.difference(a).inDays;
  }

  /// The bucket this falls in, measured against [now].
  ///
  /// Boundaries: 0–7 days is this week, 8–30 is this month, 31+ is later.
  DeadlineUrgency urgency(DateTime now) {
    final days = daysRemaining(now);
    if (days == null) return DeadlineUrgency.unknown;
    if (days < 0) return DeadlineUrgency.overdue;
    if (days <= 7) return DeadlineUrgency.thisWeek;
    if (days <= 30) return DeadlineUrgency.thisMonth;
    return DeadlineUrgency.later;
  }

  /// The timing in plain words: "in 3 weeks", "overdue by 2 days", "sometime in
  /// March 2026 — I'm not sure of the exact date".
  ///
  /// Approximate items never get a day-count, in either direction. Telling
  /// somebody they are "overdue by 43 days" on a date we inferred from "some
  /// time in 2026" would be both false and unkind.
  String timing(DateTime now) {
    final days = daysRemaining(now);
    if (days == null) return 'No date yet — worth pinning down';

    if (isApproximate) {
      final window = approximateLabel ?? _monthYear(dueDate!);
      return days < 0
          ? 'around $window — that window may already have passed'
          : 'sometime in $window — I\'m not sure of the exact date';
    }

    if (days < 0) {
      final late = -days;
      return late == 1 ? 'overdue by 1 day' : 'overdue by $late days';
    }
    if (days == 0) return 'today';
    if (days == 1) return 'tomorrow';
    if (days < 14) return 'in $days days';
    if (days < 60) {
      final weeks = (days / 7).round();
      return weeks == 1 ? 'in 1 week' : 'in $weeks weeks';
    }
    final months = (days / 30).round();
    return months == 1 ? 'in 1 month' : 'in $months months';
  }

  /// The date stamp itself. "12 Sep 2026" when known to the day, the window
  /// label when not, and an em dash when there is no date at all.
  String get dateLabel {
    final due = dueDate;
    if (due == null) return '—';
    if (isApproximate) return approximateLabel ?? _monthYear(due);
    return '${due.day} ${_monthsShort[due.month - 1]} ${due.year}';
  }

  static String _monthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';

  /// Month name for a 1-based month, for callers building approximate labels.
  static String monthName(int month) =>
      (month >= 1 && month <= 12) ? _months[month - 1] : '';

  Deadline copyWith({
    String? title,
    String? description,
    DateTime? dueDate,
    bool? isApproximate,
    String? approximateLabel,
    DeadlineSeverity? severity,
    DeadlineSource? source,
    String? relatedNodeId,
    bool? dismissible,
    String? consequence,
    String? nextAction,
    bool clearDueDate = false,
  }) => Deadline(
    id: id,
    title: title ?? this.title,
    description: description ?? this.description,
    dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
    isApproximate: isApproximate ?? this.isApproximate,
    approximateLabel: clearDueDate
        ? null
        : (approximateLabel ?? this.approximateLabel),
    severity: severity ?? this.severity,
    source: source ?? this.source,
    relatedNodeId: relatedNodeId ?? this.relatedNodeId,
    dismissible: dismissible ?? this.dismissible,
    consequence: consequence ?? this.consequence,
    nextAction: nextAction ?? this.nextAction,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'due_date': dueDate?.toIso8601String(),
    'is_approximate': isApproximate,
    'approximate_label': approximateLabel,
    'severity': severity.wire,
    'source': source.wire,
    'related_node_id': relatedNodeId,
    'dismissible': dismissible,
    'consequence': consequence,
    'next_action': nextAction,
  };

  factory Deadline.fromJson(Map<String, dynamic> j) => Deadline(
    id: j['id'] as String? ?? '',
    title: j['title'] as String? ?? '',
    description: j['description'] as String? ?? '',
    // An unparseable date reads as "no date", never as today.
    dueDate: DateTime.tryParse(j['due_date'] as String? ?? ''),
    isApproximate: j['is_approximate'] as bool? ?? false,
    approximateLabel: j['approximate_label'] as String?,
    severity: DeadlineSeverity.parse(j['severity'] as String?),
    source: DeadlineSource.parse(j['source'] as String?),
    relatedNodeId: j['related_node_id'] as String?,
    dismissible: j['dismissible'] as bool? ?? true,
    consequence: j['consequence'] as String? ?? '',
    nextAction: j['next_action'] as String? ?? '',
  );

  /// Display order: nearest bucket first, then by date, then by weight.
  ///
  /// Undated items sort last within their bucket rather than being dropped —
  /// "we do not know when" is a thing the reader needs to see, not hide.
  static int compare(Deadline a, Deadline b, DateTime now) {
    final byUrgency = a.urgency(now).rank.compareTo(b.urgency(now).rank);
    if (byUrgency != 0) return byUrgency;

    final da = a.dueDate;
    final db = b.dueDate;
    if (da != null && db != null && !da.isAtSameMomentAs(db)) {
      return da.compareTo(db);
    }
    if (da == null && db != null) return 1;
    if (da != null && db == null) return -1;

    final bySeverity = a.severity.rank.compareTo(b.severity.rank);
    if (bySeverity != 0) return bySeverity;
    return a.title.compareTo(b.title);
  }

  static List<Deadline> sorted(Iterable<Deadline> items, DateTime now) =>
      items.toList()..sort((a, b) => compare(a, b, now));

  @override
  bool operator ==(Object other) => other is Deadline && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Deadline($id, $dateLabel)';
}
