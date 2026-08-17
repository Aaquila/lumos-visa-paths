import 'package:flutter/material.dart';

import 'google_sign_in_button_stub.dart'
    if (dart.library.js_interop) 'google_sign_in_button_web.dart'
    as impl;

/// The sign-in control.
///
/// On the web this is Google's own rendered GIS button — the SDK will not
/// authenticate from custom UI, and rendering their button is also what
/// Google's branding terms require. Everywhere else it is our own pill, which
/// calls `AuthService.signInWithGoogle()` directly.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) =>
      impl.buildGoogleSignInButton(context, width: width);
}
