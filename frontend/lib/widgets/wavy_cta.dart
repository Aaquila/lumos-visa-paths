import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The one hero CTA per page. It is a pill whose right edge is a hand-drawn
/// wavy contour rather than a clean semicircle — used exactly once, never on a
/// secondary or repeated action (design doc, "Button Geometry").
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

  /// The wave rolls slowly, so the sketched edge reads as drawn, not clipped.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A pill whose edge ripples forever is exactly the kind of ambient motion
    // "reduce motion" exists to stop. Park it on a fixed phase instead — the
    // sketched contour is still there, it just holds still.
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
                  // Extra right padding leaves room for the wavy tail.
                  padding: const EdgeInsets.fromLTRB(
                    T.s40,
                    T.s16,
                    T.s56,
                    T.s16,
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

  /// Draws the keyboard focus ring — the sketched contour means a plain
  /// rectangular outline would not sit on the shape, so the ring follows the
  /// same path the fill does.
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final r = h / 2;
    final path = Path()..moveTo(r, 0);

    // Flat top edge up to the start of the tail.
    path.lineTo(size.width - r, 0);

    // Wavy right cap: a semicircle whose radius ripples.
    const steps = 44;
    for (var i = 0; i <= steps; i++) {
      final a = -math.pi / 2 + math.pi * (i / steps);
      final wobble = 1 + 0.075 * math.sin(a * 4 + phase);
      final rr = r * wobble;
      path.lineTo(size.width - r + rr * math.cos(a), r + rr * math.sin(a));
    }

    path
      ..lineTo(r, h)
      // Clean semicircular cap on the left — only the tail is sketched.
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r), clockwise: true)
      ..close();

    // Sky Wash glow, drawn as a soft halo rather than an elevation shadow so it
    // stays centred on the sketched outline.
    canvas.drawPath(
      path,
      Paint()
        ..color = T.skyWash.withValues(alpha: 0.75)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawPath(path, Paint()..color = color);

    if (focused) {
      canvas.drawPath(
        path,
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
