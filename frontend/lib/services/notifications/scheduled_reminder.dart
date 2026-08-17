import 'package:flutter/foundation.dart';

/// What a reminder is *about*.
///
/// Deliberately generic. This layer knows nothing about visas, deadlines or
/// cases — the deadline model lives elsewhere and is mapped onto
/// [ScheduledReminder] at the call site, so neither side has to know the other.
enum ReminderType {
  /// A filing or response date that has a real consequence if it slips.
  deadline('Filing deadlines', 'Dates where being late has a real cost.'),

  /// A document that stops being valid on a date — passport, I-94, EAD.
  document('Document expiry', 'Passports, I-94s, work permits running out.'),

  /// A policy or news change matched to this person's status.
  policyUpdate(
    'Policy changes',
    'Only changes that touch the status you are on.',
  ),

  /// A biometrics slot, interview, or similar appointment.
  appointment('Appointments', 'Biometrics, interviews, in-person slots.');

  const ReminderType(this.label, this.blurb);

  final String label;
  final String blurb;

  static ReminderType byName(String name, {ReminderType fallback = deadline}) {
    for (final t in values) {
      if (t.name == name) return t;
    }
    return fallback;
  }
}

/// The one value type this whole notification layer speaks.
///
/// It is intentionally tiny and owns no domain knowledge: anything that wants
/// to be reminded about something builds one of these. `id` is the caller's
/// identity for the reminder and is what [NotificationService.cancel] takes.
@immutable
class ScheduledReminder {
  const ScheduledReminder({
    required this.id,
    required this.title,
    required this.body,
    required this.fireAt,
    this.deepLink,
    this.type = ReminderType.deadline,
    this.groupKey,
    this.dueAt,
    this.allDay = false,
  });

  /// Stable, caller-chosen. Scheduling the same id twice replaces the first.
  final String id;

  /// One calm line. Shown as the notification heading and the calendar
  /// event SUMMARY.
  final String title;

  /// The supporting sentence. Never guilt-shaped — see [ReminderCopy].
  final String body;

  /// When the person should be told.
  final DateTime fireAt;

  /// In-app route to open when the notification is clicked, e.g.
  /// `/dashboard?deadline=abc`. Null means "just focus the app".
  final String? deepLink;

  final ReminderType type;

  /// Everything derived from one underlying thing (one deadline, one document)
  /// shares a group key. The "never more than one notification per day per
  /// deadline" rule is enforced on this. Defaults to [id] when unset.
  final String? groupKey;

  /// The moment the thing is actually *due*, when that differs from when we
  /// nudge. This is what becomes the calendar event; [fireAt] becomes its
  /// alarm. Null means the reminder and the event are the same moment.
  final DateTime? dueAt;

  /// True when the underlying thing is a date, not a time — a filing deadline
  /// rather than a 09:40 biometrics slot. Controls `VALUE=DATE` in the .ics.
  final bool allDay;

  /// The group this reminder is rate-limited within.
  String get group => groupKey ?? id;

  /// The moment the calendar event should sit on.
  DateTime get eventAt => dueAt ?? fireAt;

  /// How far ahead of the due date this nudge lands, floored at zero.
  Duration get leadTime {
    final d = eventAt.difference(fireAt);
    return d.isNegative ? Duration.zero : d;
  }

  bool isDue(DateTime now) => !fireAt.isAfter(now);

  ScheduledReminder copyWith({
    String? id,
    String? title,
    String? body,
    DateTime? fireAt,
    String? deepLink,
    ReminderType? type,
    String? groupKey,
    DateTime? dueAt,
    bool? allDay,
  }) => ScheduledReminder(
    id: id ?? this.id,
    title: title ?? this.title,
    body: body ?? this.body,
    fireAt: fireAt ?? this.fireAt,
    deepLink: deepLink ?? this.deepLink,
    type: type ?? this.type,
    groupKey: groupKey ?? this.groupKey,
    dueAt: dueAt ?? this.dueAt,
    allDay: allDay ?? this.allDay,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'fireAt': fireAt.toIso8601String(),
    if (deepLink != null) 'deepLink': deepLink,
    'type': type.name,
    if (groupKey != null) 'groupKey': groupKey,
    if (dueAt != null) 'dueAt': dueAt!.toIso8601String(),
    'allDay': allDay,
  };

  factory ScheduledReminder.fromJson(Map<String, dynamic> j) =>
      ScheduledReminder(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        fireAt:
            DateTime.tryParse(j['fireAt'] as String? ?? '') ?? DateTime(2000),
        deepLink: j['deepLink'] as String?,
        type: ReminderType.byName(j['type'] as String? ?? ''),
        groupKey: j['groupKey'] as String?,
        dueAt: DateTime.tryParse(j['dueAt'] as String? ?? ''),
        allDay: j['allDay'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is ScheduledReminder &&
      other.id == id &&
      other.title == title &&
      other.body == body &&
      other.fireAt == fireAt &&
      other.deepLink == deepLink &&
      other.type == type &&
      other.groupKey == groupKey &&
      other.dueAt == dueAt &&
      other.allDay == allDay;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    body,
    fireAt,
    deepLink,
    type,
    groupKey,
    dueAt,
    allDay,
  );

  @override
  String toString() => 'ScheduledReminder($id @ $fireAt: $title)';
}

/// Where the browser currently stands on letting us show notifications.
enum NotificationPermission {
  /// Never asked. The only state in which [NotificationService.requestPermission]
  /// will show the browser prompt.
  notAsked,

  granted,

  /// Denied. Browsers will not re-prompt — the user has to change it in site
  /// settings, and the UI says so rather than showing a dead button.
  denied,

  /// No Notification API at all (a non-web build, or a browser without it).
  unsupported,
}

/// The words we use.
///
/// Kept in one place because tone is a product requirement here, not a detail:
/// this app is used by people who are already frightened of these dates. No
/// exclamation marks, no "you missed", no countdown-to-doom framing.
class ReminderCopy {
  const ReminderCopy._();

  /// A reminder for something still ahead.
  static String ahead(String what, int daysAway) {
    if (daysAway <= 0) return '$what is due today. Here is what it needs.';
    if (daysAway == 1) return '$what is due tomorrow. Here is what it needs.';
    return '$what is due in $daysAway days. There is time — here is what it '
        'needs.';
  }

  /// A reminder whose moment went by while the app was closed.
  ///
  /// Never "you missed this". The date passing is information, not a verdict.
  static String past(String what, int daysAgo) {
    final when = switch (daysAgo) {
      <= 0 => 'earlier today',
      1 => 'yesterday',
      _ => '$daysAgo days ago',
    };
    return '$what passed $when. This one has passed — here is what to do now.';
  }
}
