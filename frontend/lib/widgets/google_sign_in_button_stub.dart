import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'google_glyph.dart';
import 'pill_button.dart' show focusRing;

/// Non-web implementation: our own pill, calling the SDK's native flow.
Widget buildGoogleSignInButton(BuildContext context, {required double width}) =>
    const _NativeGoogleButton();

class _NativeGoogleButton extends StatefulWidget {
  const _NativeGoogleButton();

  @override
  State<_NativeGoogleButton> createState() => _NativeGoogleButtonState();
}

class _NativeGoogleButtonState extends State<_NativeGoogleButton> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AuthService.instance,
      builder: (context, _) {
        final busy = AuthService.instance.isBusy;
        final label = busy ? 'Signing you in…' : 'Sign in with Google';

        return Semantics(
          button: true,
          enabled: !busy,
          label: label,
          onTap: busy ? null : AuthService.instance.signInWithGoogle,
          child: FocusableActionDetector(
            enabled: !busy,
            mouseCursor: busy
                ? SystemMouseCursors.wait
                : SystemMouseCursors.click,
            onShowHoverHighlight: (v) => setState(() => _hover = v),
            onShowFocusHighlight: (v) => setState(() => _focused = v),
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  AuthService.instance.signInWithGoogle();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              // Semantics are declared by the Semantics wrapper above this
              // control; without this the detector emits a second, unlabelled
              // tappable node beside it.
              excludeFromSemantics: true,
              onTap: busy
                  ? null
                  : () => AuthService.instance.signInWithGoogle(),
              child: AnimatedContainer(
                duration: Motion.duration(
                  context,
                  const Duration(milliseconds: 160),
                ),
                height: 52,
                decoration: BoxDecoration(
                  color: _hover ? const Color(0xFFF5F7F9) : T.paper,
                  border: Border.fromBorderSide(T.hairline),
                  borderRadius: BorderRadius.circular(T.rPill),
                  boxShadow: _focused
                      ? focusRing()
                      : (_hover ? T.floatShadow : null),
                ),
                alignment: Alignment.center,
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (busy)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        const GoogleGlyph(size: 19),
                      const SizedBox(width: 12),
                      Text(
                        label,
                        style: AppTheme.label.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: T.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
