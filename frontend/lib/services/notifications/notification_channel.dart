import 'scheduled_reminder.dart';

/// The thin seam between "we decided to tell the user something" and "the
/// platform actually drew a notification".
///
/// Only two implementations exist: the browser one, and a no-op used on any
/// non-web target and in tests. Everything above this line — planning,
/// preferences, catch-up, .ics — is pure Dart and testable without either.
abstract class NotificationChannel {
  /// Called when the user clicks a notification that carried a deep link.
  ///
  /// The channel deliberately does not know what a route is or how to navigate;
  /// whoever owns the router hands a callback down. Nothing in this layer
  /// imports go_router.
  void Function(String deepLink)? onOpen;

  NotificationPermission get permission;

  /// Whether the platform can show notifications at all. False on a VM/test
  /// target and in browsers without the Notification API.
  bool get isSupported;

  /// Shows the browser's own permission prompt. Returns the resulting state.
  ///
  /// Browsers only prompt once ever; once denied, this resolves straight back
  /// to [NotificationPermission.denied] without showing anything, which is why
  /// the settings UI explains how to undo it rather than offering a retry.
  Future<NotificationPermission> requestPermission();

  /// Draws a notification right now. Returns false when it could not be shown
  /// (no permission, no support) so callers can fall back to in-app UI instead
  /// of silently doing nothing.
  Future<bool> show(ScheduledReminder reminder);

  /// Registers the service worker, if the platform has one. Safe to call more
  /// than once. Returns false when there is nothing to register.
  Future<bool> ensureServiceWorker();

  /// True once a service worker is registered — the precondition for any future
  /// Web Push work.
  bool get hasServiceWorker;
}

/// Does nothing, successfully.
///
/// This is what runs under `flutter test` and on any non-web target, so the
/// service can be constructed and exercised in a unit test without a DOM.
class NoopNotificationChannel extends NotificationChannel {
  @override
  NotificationPermission get permission => NotificationPermission.unsupported;

  @override
  bool get isSupported => false;

  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.unsupported;

  @override
  Future<bool> show(ScheduledReminder reminder) async => false;

  @override
  Future<bool> ensureServiceWorker() async => false;

  @override
  bool get hasServiceWorker => false;
}
