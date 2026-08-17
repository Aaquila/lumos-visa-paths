import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The one hero CTA per page. A clean pill with a light streak that travels
/// endlessly around its border — used exactly once, never on a secondary or
/// repeated action (design doc, "Button Geometry").
class WavyCta extends StatefulWidget {
  const WavyCta({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  State<WavyCta> createState() => _WavyCtaState();
}

class _WavyCtaState extends State<WavyCta> with SingleTickerProviderStateMixin {
  bool _hover = false;
  bool _focused = false;

  /// One lap of the border per cycle — slow enough to read as ambient, not
  /// distracting.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A border that travels forever is exactly the kind of ambient motion
    // "reduce motion" exists to stop. Park it on a fixed phase instead.
    if (Motion.reduced(context)) {
      _wave.stop();
      _wave.value = 0;
    } else if (!_wave.isAnimating) {
      _wave.repeat();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);

    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          // Semantics are declared by the Semantics wrapper above this
          // control; without this the detector emits a second, unlabelled
          // tappable node beside it.
          excludeFromSemantics: true,
          onTap: widget.onPressed,
          child: AnimatedScale(
            duration: Motion.duration(
              context,
              const Duration(milliseconds: 180),
            ),
            scale: _hover && !reduced ? 1.02 : 1,
            child: AnimatedBuilder(
              animation: _wave,
              builder: (context, child) => CustomPaint(
                painter: _WavyPillPainter(
                  phase: _wave.value * math.pi * 2,
                  color: _hover ? const Color(0xFF0070E0) : T.signalBlue,
                  focused: _focused,
                ),
                child: child,
              ),
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: T.s32,
                    vertical: T.s16,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.label,
                        style: AppTheme.label.copyWith(
                          color: T.paper,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.36,
                        ),
                      ),
                      if (widget.icon != null) ...[
                        const SizedBox(width: 10),
                        AnimatedSlide(
                          duration: Motion.duration(
                            context,
                            const Duration(milliseconds: 180),
                          ),
                          offset: Offset(_hover && !reduced ? 0.25 : 0, 0),
                          child: Icon(widget.icon, size: 18, color: T.paper),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavyPillPainter extends CustomPainter {
  _WavyPillPainter({
    required this.phase,
    required this.color,
    required this.focused,
  });

  final double phase;
  final Color color;

  /// Draws the keyboard focus ring, following the same pill the fill does.
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );

    // Sky Wash glow, drawn as a soft halo rather than an elevation shadow.
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = T.skyWash.withValues(alpha: 0.75)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawRRect(rrect, Paint()..color = color);

    // A light streak that travels endlessly around the border — a simple
    // stand-in for the old hand-sketched wobble.
    canvas.drawRRect(
      rrect.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = SweepGradient(
          colors: const [
            Colors.transparent,
            Colors.transparent,
            Colors.white,
            Colors.transparent,
            Colors.transparent,
          ],
          stops: const [0, 0.42, 0.5, 0.58, 1],
          transform: GradientRotation(phase),
        ).createShader(Offset.zero & size),
    );

    if (focused) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = T.ink,
      );
    }
  }

  @override
  bool shouldRepaint(_WavyPillPainter old) =>
      old.phase != phase || old.color != color || old.focused != focused;
}
