/*
 * Lumos service worker.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHAT THIS FILE DOES TODAY
 * ─────────────────────────────────────────────────────────────────────────────
 *  1. Owns notification display, so a reminder shown from the Dart side goes
 *     through registration.showNotification() and therefore survives the tab
 *     being backgrounded on mobile Chrome.
 *  2. Handles notification clicks: focuses an existing Lumos tab if one is
 *     open, otherwise opens one, and routes to the reminder's deep link.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHAT THIS FILE DOES *NOT* DO — READ BEFORE PROMISING ANYONE PUSH
 * ─────────────────────────────────────────────────────────────────────────────
 * Notifications DO NOT fire while the Lumos tab is closed. They cannot. A
 * service worker is not a background timer — the browser terminates it within
 * seconds of going idle and only ever wakes it for an incoming event. The only
 * event that wakes it with the tab closed is a *push message from a push
 * service*, and that requires a server.
 *
 * TODO(push): to make closed-tab reminders real, all five of these are needed.
 * None of them can be faked client-side, and none of them exist in this repo:
 *
 *   1. VAPID key pair. Generate once (`web-push generate-vapid-keys`). The
 *      public key ships to the client; the private key must live only on the
 *      server and must never be committed.
 *   2. A subscribe call on the client:
 *        registration.pushManager.subscribe({
 *          userVisibleOnly: true,
 *          applicationServerKey: <VAPID public key, base64url → Uint8Array>,
 *        })
 *      This returns a PushSubscription: an endpoint URL owned by the browser
 *      vendor's push service, plus p256dh and auth encryption keys.
 *   3. Subscription storage on the backend — a table keyed by user id holding
 *      { endpoint, p256dh, auth, created_at }, with removal on 404/410 from the
 *      push service (that is how a browser tells you a subscription is dead).
 *   4. A scheduler on the backend: a job that wakes on the deadline schedule,
 *      finds due reminders, and posts an encrypted payload to each stored
 *      endpoint signed with the VAPID private key (`web-push` on Node,
 *      `pywebpush` on Python).
 *   5. The `push` listener below, un-stubbed, to draw the notification from
 *      the delivered payload.
 *
 * Until all five exist, the honest user-facing statement — which the settings
 * screen makes in plain English — is: "reminders appear while Lumos is open,
 * and we catch you up on anything you missed when you come back. For dates
 * that must reach you when Lumos is closed, export them to your calendar."
 */

const LUMOS_SW_VERSION = 'lumos-sw-v1';

self.addEventListener('install', (event) => {
  // No precache: the Flutter build already has its own asset versioning, and
  // caching its output from here would fight it. Take over immediately.
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

/*
 * Notification click → open or focus Lumos on the right screen.
 *
 * `data.deepLink` is set by lib/services/notifications/notification_channel_web
 * .dart. It is an in-app route ('/dashboard?deadline=abc'), never an external
 * URL, and is resolved against this worker's own scope so a malformed value
 * cannot navigate a user off-origin.
 */
self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  const raw = (event.notification.data && event.notification.data.deepLink) || '';
  let target = self.registration.scope;
  if (raw) {
    try {
      const resolved = new URL(raw, self.registration.scope);
      // Same-origin only. A deep link is a route, not a redirect.
      if (resolved.origin === self.location.origin) {
        target = resolved.href;
      }
    } catch (e) {
      // Unparseable link: fall back to the app root rather than doing nothing.
    }
  }

  event.waitUntil(
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then((clientList) => {
        for (const client of clientList) {
          if (client.url.startsWith(self.location.origin) && 'focus' in client) {
            if ('navigate' in client && target !== client.url) {
              return client.navigate(target).then((c) => (c ? c.focus() : null));
            }
            return client.focus();
          }
        }
        return self.clients.openWindow(target);
      })
  );
});

/*
 * TODO(push): step 5. This listener is the only thing that can fire a
 * notification with every Lumos tab closed — and it never runs until a server
 * is posting to this browser's push endpoint (steps 1-4 above).
 *
 * Left registered and inert on purpose: the wiring is structural, so dropping
 * real push in later is this handler's body plus a subscribe call, not a
 * rewrite.
 */
self.addEventListener('push', (event) => {
  if (!event.data) return;

  let payload;
  try {
    payload = event.data.json();
  } catch (e) {
    payload = { title: 'Lumos', body: event.data.text() };
  }

  event.waitUntil(
    self.registration.showNotification(payload.title || 'Lumos', {
      body: payload.body || '',
      icon: 'icons/Icon-192.png',
      badge: 'icons/Icon-192.png',
      // Same calm defaults as the in-page path: one per deadline, no sound,
      // no forced interaction.
      tag: payload.tag || payload.id || 'lumos',
      renotify: false,
      requireInteraction: false,
      silent: true,
      data: { deepLink: payload.deepLink || '' },
    })
  );
});

/*
 * TODO(push): when the push service rotates a subscription it fires this event
 * instead of telling the server. Re-subscribing and re-posting to the backend
 * belongs here, otherwise reminders silently stop for that device.
 */
self.addEventListener('pushsubscriptionchange', (event) => {
  // Intentionally empty until subscription storage exists.
});
