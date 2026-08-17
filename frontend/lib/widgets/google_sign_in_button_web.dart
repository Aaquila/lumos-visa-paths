import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart' as gis;

/// Web implementation: Google Identity Services will only complete an
/// authentication from its own button, so that is what we render. Sign-in
/// results arrive on `GoogleSignIn.instance.authenticationEvents`, which
/// `AuthService` already listens to.
Widget buildGoogleSignInButton(BuildContext context, {required double width}) {
  return Align(
    child: SizedBox(
      width: width,
      child: gis.renderButton(
        configuration: gis.GSIButtonConfiguration(
          theme: gis.GSIButtonTheme.outline,
          size: gis.GSIButtonSize.large,
          text: gis.GSIButtonText.signinWith,
          shape: gis.GSIButtonShape.pill,
          logoAlignment: gis.GSIButtonLogoAlignment.left,
          minimumWidth: width,
        ),
      ),
    ),
  );
}
