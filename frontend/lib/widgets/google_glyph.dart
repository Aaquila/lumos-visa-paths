import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Google's four-colour "G", drawn rather than shipped as an asset so the
/// sign-in button stays self-contained.
class GoogleGlyph extends StatelessWidget {
  const GoogleGlyph({super.key, this.size = 18});

  final double size;

  /// The glyph is always drawn next to the words "Sign in with Google", so it
  /// is decoration — announcing "Google logo" after that label is redundant.
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(size: Size.square(size), painter: _GooglePainter()),
  );
}

class _GooglePainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _red = Color(0xFFEA4335);
  static const _yellow = Color(0xFFFBBC05);
  static const _green = Color(0xFF34A853);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.22;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Ring quadrants, starting from the right and running clockwise.
    void seg(double startDeg, double sweepDeg, Color color) {
      canvas.drawArc(
        rect,
        startDeg * math.pi / 180,
        sweepDeg * math.pi / 180,
        false,
        arc..color = color,
      );
    }

    seg(-70, 45, _red); // top right
    seg(-115, -105, _yellow); // left
    seg(140, 80, _green); // bottom
    seg(-25, 60, _blue); // right, into the bar

    // The G's horizontal bar.
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.5,
        size.height * 0.42,
        size.width * 0.5 - stroke / 2,
        stroke * 0.9,
      ),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(_GooglePainter oldDelegate) => false;
}
