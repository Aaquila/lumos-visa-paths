import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'notification_channel.dart';
import 'scheduled_reminder.dart';

NotificationChannel createNotificationChannel() => WebNotificationChannel();

// ── Interop ────────────────────────────────────────────────────────────────
//
// Hand-written against dart:js_interop rather than package:web, because
// package:web is not a declared dependency of this project and this file needs
// exactly four things from the browser: the Notification constructor, its
// permission string, its permission prompt, and serviceWorker.register.

@JS('Notification')
extension type _JsNotification._(JSObject _) implements JSObject {
  external factory _JsNotification(String title, JSObject options);
  external set onclick(JSFunction f);
  external void close();
}

@JS('Notification.permission')
external String get _rawPermission;

@JS('Notification.requestPermission')
external JSAny? _rawRequestPermission();

@JS('window.focus')
external void _focusWindow();

/// [ServiceWorkerRegistration.showNotification] — the only way to show a
/// notification that survives the page being backgrounded on Android Chrome,
/// and the same call a future push handler would make.
extension type _SwRegistration._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> showNotification(String title, JSObject options);
}

/// The browser implementation of [NotificationChannel].
///
/// ## What this genuinely does
/// Shows OS-level notifications while the Lumos tab is open (foreground or
/// backgrounded). That is the entire capability of the Notification API on its
/// own.
///
/// ## What it does NOT do, and cannot from here
/// Fire while the tab is **closed**. That requires Web Push: a VAPID key pair,
/// a `PushManager.subscribe()` call, somewhere on a server to store the
/// resulting subscription, and a server that signs and posts to the push
/// endpoint when a deadline comes due. None of that exists in this repo and
/// none of it can be faked client-side. See the TODO block in `web/sw.js` for
/// the exact list of what is missing.
class WebNotificationChannel extends NotificationChannel {
  bool _swRegistered = false;
  _SwRegistration? _registration;

  @override
  bool get isSupported => globalContext.has('Notification');

  @override
  NotificationPermission get permission {
    if (!isSupported) return NotificationPermission.unsupported;
    try {
      return switch (_rawPermission) {
        'granted' => NotificationPermission.granted,
        'denied' => NotificationPermission.denied,
        _ => NotificationPermission.notAsked,
      };
    } catch (_) {
      return NotificationPermission.unsupported;
    }
  }

  @override
  Future<NotificationPermission> requestPermission() async {
    if (!isSupported) return NotificationPermission.unsupported;
    // Already decided: browsers will not re-prompt, so do not pretend to try.
    final current = permission;
    if (current != NotificationPermission.notAsked) return current;

    try {
      final result = _rawRequestPermission();
      // Modern browsers return a Promise; older Safari took a callback and
      // returned undefined, in which case the permission string is updated
      // synchronously-ish and reading it back is the best we can do.
      if (result.isA<JSPromise>()) {
        await (result as JSPromise<JSAny?>).toDart;
      }
    } catch (_) {
      // A throwing prompt (insecure origin, sandboxed frame) is a "no".
      return permission;
    }
    return permission;
  }

  @override
  bool get hasServiceWorker => _swRegistered;

  @override
  Future<bool> ensureServiceWorker() async {
    if (_swRegistered) return true;
    try {
      final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
      final container = navigator?.getProperty<JSObject?>('serviceWorker'.toJS);
      if (container == null) return false;

      // web/index.html registers on load; this resolves against whatever is
      // already there and only registers if that has not happened yet.
      final ready = container.getProperty<JSPromise<JSAny?>?>('ready'.toJS);
      if (ready != null) {
        final reg = await ready.toDart;
        if (reg.isA<JSObject>()) {
          _registration = _SwRegistration._(reg as JSObject);
          _swRegistered = true;
        }
        return _swRegistered;
      }
    } catch (_) {
      // No service worker is a degraded but working state: in-tab notifications
      // still fire. Nothing here should be fatal.
    }
    return false;
  }

  @override
  Future<bool> show(ScheduledReminder reminder) async {
    if (permission != NotificationPermission.granted) return false;

    final options = JSObject()
      ..setProperty('body'.toJS, reminder.body.toJS)
      ..setProperty('icon'.toJS, 'icons/Icon-192.png'.toJS)
      ..setProperty('badge'.toJS, 'icons/Icon-192.png'.toJS)
      // One notification per group replaces the previous one rather than
      // stacking — the "never more than one per day per deadline" rule, made
      // belt-and-braces at the OS level.
      ..setProperty('tag'.toJS, reminder.group.toJS)
      // Calm by default: no sound, no vibration, no `requireInteraction`. It
      // waits in the tray until the person is ready for it.
      ..setProperty('silent'.toJS, true.toJS)
      ..setProperty('renotify'.toJS, false.toJS)
      ..setProperty('requireInteraction'.toJS, false.toJS)
      ..setProperty(
        'timestamp'.toJS,
        reminder.fireAt.millisecondsSinceEpoch.toJS,
      )
      ..setProperty(
        'data'.toJS,
        (JSObject()
          ..setProperty('id'.toJS, reminder.id.toJS)
          ..setProperty('deepLink'.toJS, (reminder.deepLink ?? '').toJS)),
      );

    // Prefer the service worker: its notifications outlive a backgrounded page
    // on mobile Chrome, and it is the same code path Web Push would use.
    final reg = _registration;
    if (reg != null) {
      try {
        await reg.showNotification(reminder.title, options).toDart;
        return true;
      } catch (_) {
        // Fall through to the page-level constructor.
      }
    }

    try {
      final n = _JsNotification(reminder.title, options);
      final link = reminder.deepLink;
      n.onclick = ((JSAny? _) {
        try {
          _focusWindow();
        } catch (_) {}
        if (link != null && link.isNotEmpty) onOpen?.call(link);
        n.close();
      }).toJS;
      return true;
    } catch (_) {
      return false;
    }
  }
}
