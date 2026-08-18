import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app/router.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  // Restores a stored session and wires up Google Identity Services before the
  // first frame, so a signed-in visitor never flashes the logged-out nav.
  await AuthService.instance.initialize();

  // Reminders live in the browser, so nothing fires while the tab is shut.
  // Initializing before the first frame is what replays anything whose moment
  // passed while the person was away. The service deliberately knows nothing
  // about routing, so it is handed a way to navigate rather than importing one.
  NotificationService.instance.onOpenDeepLink = appRouter.go;
  await NotificationService.instance.initialize();

  runApp(const LumosApp());
}

class LumosApp extends StatelessWidget {
  const LumosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Lumos — your immigration assistant',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      routerConfig: appRouter,
      // Keep the layout predictable at large accessibility text sizes rather
      // than letting oversized display type overflow the hero.
      builder: (context, child) {
        final scaler = MediaQuery.textScalerOf(
          context,
        ).clamp(minScaleFactor: 1.0, maxScaleFactor: 1.3);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
