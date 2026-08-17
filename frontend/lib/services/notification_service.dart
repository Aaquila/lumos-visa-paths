import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notifications/notification_channel.dart';
import 'notifications/notification_channel_stub.dart'
    if (dart.library.js_interop) 'notifications/notification_channel_web.dart';
import 'notifications/notification_preferences.dart';
import 'notifications/reminder_planner.dart';
import 'notifications/scheduled_reminder.dart';

export 'notifications/notification_channel.dart' show NotificationChannel;
export 'notifications/notification_preferences.dart';
export 'notifications/reminder_planner.dart';
export 'notifications/scheduled_reminder.dart';

/// Lumos's reminder layer.
///
/// ## What it knows
/// [ScheduledReminder] and nothing else. It has never heard of a visa, a
/// deadline model, a case or a pathway — whoever owns those maps them onto a
/// reminder and hands it in. That keeps this file compilable and testable
/// independently of the domain model, and means a change to the deadline shape
/// cannot break notifications.
///
/// ## What actually reaches the user
/// | Situation | Does it fire? |
/// |---|---|
/// | Lumos tab open, focused or backgrounded | Yes — real OS notification |
/// | Tab closed, browser open | **No** |
/// | Browser closed / device asleep | **No** |
/// | User comes back later | Yes — "while you were away" catch-up |
/// | Exported to Google/Apple Calendar | Yes — the calendar's own alarm |
///
/// The two "no" rows need Web Push, which needs a push server. There is no
/// push server in this project, so those rows are honestly labelled everywhere
/// they are shown to a user, and [IcsExport] exists to cover them properly.
///
/// ## Persistence
/// The schedule is written to SharedPreferences after every change, following
/// the pattern in `auth_service.dart` (one JSON blob, one key, defensive
/// restore). That is what makes catch-up possible: on the next [initialize] we
/// compare the stored schedule against the stored "last seen" timestamp.
class NotificationService extends ChangeNotifier {
  NotificationService._({NotificationChannel? channel})
    : _channel = channel ?? createNotificationChannel();

  static final instance = NotificationService._();

  /// A service wired to a channel you control, for tests. Never touches
  /// [instance], so a test cannot leak scheduled timers into another test.
  @visibleForTesting
  factory NotificationService.forTesting({
    NotificationChannel? channel,
    NotificationPreferencesStore? store,
  }) {
    final s = NotificationService._(
      channel: channel ?? NoopNotificationChannel(),
    );
    if (store != null) s._store = store;
    return s;
  }

  static const _scheduleKey = 'lumos.notifications.schedule';
  static const _lastSeenKey = 'lumos.notifications.lastSeen';

  /// In-session timers are only armed this far out. Beyond it a Timer is just a
  /// promise the tab will still be open in a month, which it will not be — the
  /// reminder stays on the persisted schedule and is picked up by catch-up or
  /// by the next [initialize] instead.
  static const timerHorizon = Duration(hours: 12);

  final NotificationChannel _channel;
  NotificationPreferencesStore _store = const NotificationPreferencesStore();

  final Map<String, ScheduledReminder> _scheduled = {};
  final Map<String, Timer> _timers = {};

  NotificationPreferences _prefs = const NotificationPreferences();
  NotificationPreferences get preferences => _prefs;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// Reminders whose moment passed while the app was closed, worded for the
  /// past tense. Read once by the dashboard and then [acknowledgeCatchUp]d.
  List<ScheduledReminder> _missed = const [];
  List<ScheduledReminder> get missedWhileAway => List.unmodifiable(_missed);

  /// Where a clicked notification wants to go. Whoever owns the router sets
  /// this; this layer does not import go_router.
  set onOpenDeepLink(void Function(String deepLink)? handler) =>
      _channel.onOpen = handler;

  // ── Capability ────────────────────────────────────────────────────────────

  NotificationPermission get permissionStatus => _channel.permission;
  bool get isSupported => _channel.isSupported;
  bool get canNotify =>
      _channel.permission == NotificationPermission.granted &&
      !_prefs.isSilenced(DateTime.now());

  /// The honest answer to "will this reach me when Lumos is closed?".
  ///
  /// Always false, and deliberately a getter rather than a constant so the day
  /// a push backend lands, one line here turns the whole UI truthful again.
  bool get canDeliverWhenClosed => false;

  Future<NotificationPermission> requestPermission() async {
    final result = await _channel.requestPermission();
    notifyListeners();
    if (result == NotificationPermission.granted) {
      await _rearmAll();
    }
    return result;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Restores preferences and the persisted schedule, works out what was missed
  /// while the tab was closed, and arms timers for what is imminent.
  ///
  /// Safe to call more than once; only the first call does work.
  Future<void> initialize({DateTime? now}) async {
    if (_initialized) return;
    _initialized = true;

    final at = now ?? DateTime.now();
    _prefs = await _store.load();
    await _restoreSchedule();

    final lastSeen = await _readLastSeen() ?? at;
    _missed = ReminderPlanner.catchUp(
      scheduled: _scheduled.values.toList(),
      lastSeen: lastSeen,
      now: at,
      prefs: _prefs,
    );

    // Drop anything too old to matter, so the stored blob stays small.
    _scheduled.removeWhere((_, r) => ReminderPlanner.isExpired(r, at));

    unawaited(_channel.ensureServiceWorker());
    await _persistSchedule();
    await _touchLastSeen(at);
    _armTimers(at);
    notifyListeners();
  }

  /// Marks the "while you were away" list as read.
  void acknowledgeCatchUp() {
    if (_missed.isEmpty) return;
    _missed = const [];
    notifyListeners();
  }

  /// Shows the catch-up items as real notifications, if permitted.
  ///
  /// Rate-limited by [ReminderPlanner.catchUp] to at most one per deadline per
  /// day and at most five in total, so returning after a month away is a short
  /// summary rather than an avalanche.
  Future<int> deliverCatchUp() async {
    if (!canNotify) return 0;
    var shown = 0;
    for (final r in _missed) {
      if (await _channel.show(r)) shown++;
    }
    return shown;
  }

  // ── Scheduling ────────────────────────────────────────────────────────────

  /// Adds or replaces a reminder. Same [ScheduledReminder.id] replaces.
  ///
  /// Reminders are stored even when notifications are muted or unpermitted:
  /// they are still the source for [listScheduled] and for the calendar export,
  /// which is the channel that actually works.
  Future<void> schedule(ScheduledReminder reminder) async {
    _scheduled[reminder.id] = reminder;
    _timers.remove(reminder.id)?.cancel();
    _arm(reminder, DateTime.now());
    await _persistSchedule();
    notifyListeners();
  }

  /// Bulk form — one write instead of N.
  Future<void> scheduleAll(Iterable<ScheduledReminder> reminders) async {
    final now = DateTime.now();
    for (final r in reminders) {
      _scheduled[r.id] = r;
      _timers.remove(r.id)?.cancel();
      _arm(r, now);
    }
    await _persistSchedule();
    notifyListeners();
  }

  /// Replaces every reminder in a group — how a caller updates one deadline
  /// whose date moved without leaving the old nudges behind.
  Future<void> replaceGroup(
    String groupKey,
    Iterable<ScheduledReminder> reminders,
  ) async {
    for (final id
        in _scheduled.entries
            .where((e) => e.value.group == groupKey)
            .map((e) => e.key)
            .toList()) {
      _scheduled.remove(id);
      _timers.remove(id)?.cancel();
    }
    await scheduleAll(reminders);
  }

  Future<void> cancel(String id) async {
    _timers.remove(id)?.cancel();
    if (_scheduled.remove(id) == null) return;
    await _persistSchedule();
    notifyListeners();
  }

  Future<void> cancelGroup(String groupKey) async {
    final ids = _scheduled.entries
        .where((e) => e.value.group == groupKey)
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      _timers.remove(id)?.cancel();
      _scheduled.remove(id);
    }
    if (ids.isEmpty) return;
    await _persistSchedule();
    notifyListeners();
  }

  Future<void> cancelAll() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _scheduled.clear();
    await _persistSchedule();
    notifyListeners();
  }

  /// Everything on the books, soonest first — including moments already past,
  /// which are what catch-up reads.
  List<ScheduledReminder> listScheduled() =>
      _scheduled.values.toList()..sort((a, b) => a.fireAt.compareTo(b.fireAt));

  /// Only what is still ahead.
  List<ScheduledReminder> listUpcoming({DateTime? now}) =>
      ReminderPlanner.upcoming(
        _scheduled.values.toList(),
        now ?? DateTime.now(),
      );

  /// Draws a notification immediately, bypassing the schedule. Used by the
  /// "send me a test" button and by anything that needs to say something now.
  ///
  /// Respects mute and permission — a test notification that appears while the
  /// user is muted would be a lie about how the setting behaves.
  Future<bool> showNow({
    required String title,
    required String body,
    String? deepLink,
    String id = 'lumos.adhoc',
    ReminderType type = ReminderType.deadline,
  }) async {
    if (!canNotify) return false;
    return _channel.show(
      ScheduledReminder(
        id: id,
        title: title,
        body: body,
        fireAt: DateTime.now(),
        deepLink: deepLink,
        type: type,
      ),
    );
  }

  // ── Preferences ───────────────────────────────────────────────────────────

  Future<void> updatePreferences(NotificationPreferences next) async {
    _prefs = next;
    await _store.save(next);
    await _rearmAll();
    notifyListeners();
  }

  Future<void> setMuted(bool muted) =>
      updatePreferences(_prefs.copyWith(muted: muted, clearQuietUntil: true));

  Future<void> setType(ReminderType type, bool enabled) =>
      updatePreferences(_prefs.withType(type, enabled));

  Future<void> setLeadDay(int days, bool enabled) =>
      updatePreferences(_prefs.withLeadDay(days, enabled));

  /// "Not this week." A temporary mute that expires on its own, so nobody has
  /// to remember to switch reminders back on.
  Future<void> snooze(Duration duration) => updatePreferences(
    _prefs.copyWith(quietUntil: DateTime.now().add(duration)),
  );

  // ── Timers ────────────────────────────────────────────────────────────────

  void _arm(ScheduledReminder r, DateTime now) {
    if (_prefs.isSilenced(now) || !_prefs.isTypeEnabled(r.type)) return;
    final delay = r.fireAt.difference(now);
    if (delay.isNegative || delay > timerHorizon) return;
    _timers[r.id] = Timer(delay, () {
      _timers.remove(r.id);
      unawaited(_fire(r));
    });
  }

  void _armTimers(DateTime now) {
    for (final r in _scheduled.values) {
      if (_timers.containsKey(r.id)) continue;
      _arm(r, now);
    }
  }

  Future<void> _rearmAll() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _armTimers(DateTime.now());
  }

  Future<void> _fire(ScheduledReminder r) async {
    final now = DateTime.now();
    if (!canNotify || !_prefs.isTypeEnabled(r.type)) return;
    await _channel.show(r);
    await _touchLastSeen(now);
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _persistSchedule() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _scheduleKey,
        jsonEncode(_scheduled.values.map((r) => r.toJson()).toList()),
      );
    } catch (_) {
      // A schedule that lives only in memory still fires this session; the
      // cost of failure is losing catch-up, not losing the app.
    }
  }

  Future<void> _restoreSchedule() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_scheduleKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map) continue;
        final r = ScheduledReminder.fromJson(item.cast<String, dynamic>());
        if (r.id.isEmpty) continue;
        _scheduled[r.id] = r;
      }
    } catch (_) {
      // Corrupt storage means "no schedule yet", never a crash on start-up.
    }
  }

  Future<DateTime?> _readLastSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastSeenKey);
      return raw == null ? null : DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _touchLastSeen(DateTime at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastSeenKey, at.toIso8601String());
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
