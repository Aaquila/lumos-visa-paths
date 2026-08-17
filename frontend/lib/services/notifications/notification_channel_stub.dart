import 'notification_channel.dart';

/// Non-web target (and the test VM): there is no Notification API to talk to.
NotificationChannel createNotificationChannel() => NoopNotificationChannel();
