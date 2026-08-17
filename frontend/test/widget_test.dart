import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumos/theme/app_theme.dart';
import 'package:lumos/widgets/pill_button.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: AppTheme.build(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('pill button fires once tapped and stays inert while busy', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(PillButton(label: 'Get started', onPressed: () => taps++)),
    );
    await tester.tap(find.text('Get started'));
    expect(taps, 1);

    await tester.pumpWidget(
      wrap(
        PillButton(label: 'Get started', busy: true, onPressed: () => taps++),
      ),
    );
    await tester.tap(find.text('Get started'));
    expect(taps, 1, reason: 'a busy button must not double-submit');
  });

  testWidgets('a session honours the stay-signed-in choice and clears on '
      'sign out', (tester) async {
    // SharedPreferences has no platform channel in a plain unit test.
    SharedPreferences.setMockInitialValues({});
    final auth = AuthService.instance;
    addTearDown(auth.signOut);

    expect(auth.isSignedIn, isFalse);

    await auth.continueAsDemoUser(rememberMe: true);
    expect(auth.isSignedIn, isTrue);
    expect(auth.session!.isDemo, isTrue);
    final long = auth.session!.expiresAt.difference(DateTime.now());
    expect(long.inDays, greaterThanOrEqualTo(13));

    await auth.signOut();
    expect(auth.isSignedIn, isFalse);
    expect(auth.session, isNull);

    await auth.continueAsDemoUser(rememberMe: false);
    final short = auth.session!.expiresAt.difference(DateTime.now());
    expect(short.inDays, lessThan(1));
  });

  test('initials fall back sensibly for one-word and empty names', () {
    UserSession make(String name, String email) => UserSession(
      displayName: name,
      email: email,
      expiresAt: DateTime.now().add(const Duration(days: 1)),
    );
    expect(make('Ada Lovelace', 'a@b.c').initials, 'AL');
    expect(make('Ada', 'a@b.c').initials, 'A');
    expect(make('', 'zoe@b.c').initials, 'Z');
  });
}
