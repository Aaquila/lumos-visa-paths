import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scheduled_reminder.dart';

/// What the user has told us they want to be told about.
///
/// Persisted with the same shape as [UserSession] in `auth_service.dart`: a
/// single JSON blob under one SharedPreferences key, restored defensively so a
/// corrupt or half-written value degrades to defaults instead of throwing.
@immutable
class NotificationPreferences {
  const NotificationPreferences({
    this.muted = false,
    this.leadDays = defaultLeadDays,
    this.enabledTypes = defaultTypes,
    this.quietUntil,
  });

  /// Generous on purpose. 30 days is enough time to gather documents without
  /// panicking, 7 is enough to book anything that needs booking, 1 is the
  /// "tomorrow" safety net. Nothing fires the morning of by default, because a
  /// same-day notification about a filing deadline is only ever alarming.
  static const List<int> defaultLeadDays = [30, 7, 1];

  /// The full menu of lead times a person can pick from.
  static const List<int> leadDayChoices = [90, 60, 30, 14, 7, 3, 1];

  static const Set<ReminderType> defaultTypes = {
    ReminderType.deadline,
    ReminderType.document,
    ReminderType.appointment,
    ReminderType.policyUpdate,
  };

  /// The global off switch. One tap, reversible, never buried. When true
  /// nothing is scheduled and nothing catches up — but the schedule is kept, so
  /// unmuting restores everything rather than losing it.
  final bool muted;

  /// How many days before a due date to nudge. Always sorted descending and
  /// de-duplicated by [normalised].
  final List<int> leadDays;

  final Set<ReminderType> enabledTypes;

  /// A temporary mute — "not this week". Null when not snoozed.
  final DateTime? quietUntil;

  bool isTypeEnabled(ReminderType t) => enabledTypes.contains(t);

  /// True when nothing at all should reach the user right now.
  bool isSilenced(DateTime now) =>
      muted || (quietUntil != null && now.isBefore(quietUntil!));

  /// Sorted, de-duplicated, positive, capped at a year out. Never empty — an
  /// empty lead-time list would silently mean "no reminders ever", which is
  /// what [muted] is for and should never happen by accident.
  List<int> get normalised {
    final set = leadDays.where((d) => d > 0 && d <= 365).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    return set.isEmpty ? const [1] : set;
  }

  NotificationPreferences copyWith({
    bool? muted,
    List<int>? leadDays,
    Set<ReminderType>? enabledTypes,
    DateTime? quietUntil,
    bool clearQuietUntil = false,
  }) => NotificationPreferences(
    muted: muted ?? this.muted,
    leadDays: leadDays ?? this.leadDays,
    enabledTypes: enabledTypes ?? this.enabledTypes,
    quietUntil: clearQuietUntil ? null : (quietUntil ?? this.quietUntil),
  );

  NotificationPreferences withType(ReminderType t, bool on) {
    final next = {...enabledTypes};
    if (on) {
      next.add(t);
    } else {
      next.remove(t);
    }
    return copyWith(enabledTypes: next);
  }

  NotificationPreferences withLeadDay(int days, bool on) {
    final next = {...leadDays};
    if (on) {
      next.add(days);
    } else {
      next.remove(days);
    }
    return copyWith(leadDays: next.toList());
  }

  Map<String, dynamic> toJson() => {
    'muted': muted,
    'leadDays': normalised,
    'enabledTypes': enabledTypes.map((t) => t.name).toList(),
    if (quietUntil != null) 'quietUntil': quietUntil!.toIso8601String(),
  };

  factory NotificationPreferences.fromJson(Map<String, dynamic> j) {
    final rawLead = j['leadDays'];
    final lead = rawLead is List
        ? rawLead.whereType<num>().map((n) => n.toInt()).toList()
        : defaultLeadDays;

    final rawTypes = j['enabledTypes'];
    final types = rawTypes is List
        ? {
            for (final t in ReminderType.values)
              if (rawTypes.contains(t.name)) t,
          }
        : defaultTypes;

    return NotificationPreferences(
      muted: j['muted'] as bool? ?? false,
      leadDays: lead.isEmpty ? defaultLeadDays : lead,
      enabledTypes: types,
      quietUntil: DateTime.tryParse(j['quietUntil'] as String? ?? ''),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationPreferences &&
      other.muted == muted &&
      listEquals(other.normalised, normalised) &&
      setEquals(other.enabledTypes, enabledTypes) &&
      other.quietUntil == quietUntil;

  @override
  int get hashCode => Object.hash(
    muted,
    Object.hashAll(normalised),
    Object.hashAllUnordered(enabledTypes),
    quietUntil,
  );
}

/// Reads and writes [NotificationPreferences]. Split out from the service so
/// the round-trip is testable without a browser.
class NotificationPreferencesStore {
  const NotificationPreferencesStore({this.key = storageKey});

  static const storageKey = 'lumos.notifications.prefs';

  final String key;

  Future<NotificationPreferences> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return const NotificationPreferences();
      return NotificationPreferences.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      // Unreadable settings must never block the app from starting; defaults
      // are safe (they only ever mean "remind a bit more than needed").
      return const NotificationPreferences();
    }
  }

  Future<void> save(NotificationPreferences value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(value.toJson()));
    } catch (_) {
      // Preferences that survive only in memory are still applied this session.
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }
}
