import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/onboarding_profile.dart';
import '../theme/tokens.dart';

/// The three cartoon faces on the name picker, drawn entirely in Dart.
///
/// No images, no icon font, no asset pipeline — and deliberately no photograph
/// or likeness of a person, so nobody has to see a face that is supposed to be
/// them. Each is a friendly shape with dot eyes and a smile, in the pastel
/// badge fills the design system already sanctions for small round accents.
class CartoonAvatar extends StatelessWidget {
  const CartoonAvatar({
    super.key,
    required this.kind,
    this.size = 88,
    this.selected = false,
  });

  final AvatarKind kind;
  final double size;

  /// Selected avatars get the Signal Blue outline the rest of the system uses
  /// for "this is the chosen one".
  final bool selected;

  /// The pastel each face sits on. Kept here so the card behind the avatar can
  /// tint to match without duplicating the mapping.
  static Color fillFor(AvatarKind kind) => switch (kind) {
    AvatarKind.flower => T.pastelPink,
    AvatarKind.star => T.pastelSky,
    AvatarKind.sprout => T.pastelMint,
  };

  static Color accentFor(AvatarKind kind) => switch (kind) {
    AvatarKind.flower => T.pastelLavender,
    AvatarKind.star => T.pastelYellow,
    AvatarKind.sprout => T.pastelPeach,
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _AvatarPainter(kind: kind, selected: selected),
        // The picker reads the name next to the face; the face itself is
        // decorative, so it is excluded rather than announced twice.
        isComplex: false,
      ),
    );
  }
}

class _AvatarPainter extends CustomPainter {
  const _AvatarPainter({required this.kind, required this.selected});

  final AvatarKind kind;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final unit = size.shortestSide / 100;

    final fill = Paint()..color = CartoonAvatar.fillFor(kind);
    final accent = Paint()..color = CartoonAvatar.accentFor(kind);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * unit
      ..strokeCap = StrokeCap.round
      ..color = selected ? T.signalBlue : T.ink;

    canvas.drawCircle(center, radius - unit, fill);
    canvas.drawCircle(center, radius - unit, line);

    switch (kind) {
      case AvatarKind.flower:
        _flower(canvas, center, radius, unit, accent, line);
      case AvatarKind.star:
        _star(canvas, center, radius, unit, accent, line);
      case AvatarKind.sprout:
        _sprout(canvas, center, radius, unit, accent, line);
    }

    _face(canvas, center, unit, line, kind);
  }

  /// Six petals around the middle, so the face sits in a bloom.
  void _flower(
    Canvas canvas,
    Offset center,
    double radius,
    double unit,
    Paint accent,
    Paint line,
  ) {
    const petals = 6;
    final ring = radius * 0.52;
    final petal = radius * 0.30;
    for (var i = 0; i < petals; i++) {
      final angle = (i / petals) * 2 * math.pi - math.pi / 2;
      final at = center + Offset(math.cos(angle), math.sin(angle)) * ring;
      canvas.drawCircle(at, petal, accent);
      canvas.drawCircle(at, petal, line);
    }
    canvas.drawCircle(center, radius * 0.40, Paint()..color = T.paper);
    canvas.drawCircle(center, radius * 0.40, line);
  }

  /// A five-pointed star with the face on its body.
  void _star(
    Canvas canvas,
    Offset center,
    double radius,
    double unit,
    Paint accent,
    Paint line,
  ) {
    final path = Path();
    const points = 5;
    final outer = radius * 0.74;
    final inner = radius * 0.34;
    for (var i = 0; i < points * 2; i++) {
      final r = i.isEven ? outer : inner;
      final angle = (i / (points * 2)) * 2 * math.pi - math.pi / 2;
      final at = center + Offset(math.cos(angle), math.sin(angle)) * r;
      if (i == 0) {
        path.moveTo(at.dx, at.dy);
      } else {
        path.lineTo(at.dx, at.dy);
      }
    }
    path.close();
    canvas.drawPath(path, accent);
    canvas.drawPath(path, line);
  }

  /// A stem with two leaves — a small growing thing.
  void _sprout(
    Canvas canvas,
    Offset center,
    double radius,
    double unit,
    Paint accent,
    Paint line,
  ) {
    final base = center + Offset(0, radius * 0.62);
    final top = center + Offset(0, -radius * 0.30);
    canvas.drawLine(base, top, line);

    for (final side in const [-1.0, 1.0]) {
      final leaf = Path()
        ..moveTo(center.dx, center.dy + radius * 0.28)
        ..quadraticBezierTo(
          center.dx + side * radius * 0.72,
          center.dy + radius * 0.30,
          center.dx + side * radius * 0.52,
          center.dy - radius * 0.16,
        )
        ..quadraticBezierTo(
          center.dx + side * radius * 0.18,
          center.dy - radius * 0.02,
          center.dx,
          center.dy + radius * 0.28,
        );
      canvas.drawPath(leaf, accent);
      canvas.drawPath(leaf, line);
    }

    canvas.drawCircle(
      center + Offset(0, -radius * 0.42),
      radius * 0.28,
      Paint()..color = T.paper,
    );
    canvas.drawCircle(center + Offset(0, -radius * 0.42), radius * 0.28, line);
  }

  /// Dot eyes and an upturned arc. The face sits wherever that shape put it.
  void _face(
    Canvas canvas,
    Offset center,
    double unit,
    Paint line,
    AvatarKind kind,
  ) {
    final at = switch (kind) {
      AvatarKind.flower => center,
      AvatarKind.star => center + Offset(0, unit * 2),
      AvatarKind.sprout => center + Offset(0, -unit * 21),
    };
    final scale = switch (kind) {
      AvatarKind.sprout => 0.72,
      _ => 1.0,
    };

    final eye = Paint()..color = line.color;
    final gap = unit * 7 * scale;
    final eyeR = unit * 2.2 * scale;
    canvas.drawCircle(at + Offset(-gap, -unit * 3 * scale), eyeR, eye);
    canvas.drawCircle(at + Offset(gap, -unit * 3 * scale), eyeR, eye);

    final smile = Rect.fromCircle(
      center: at + Offset(0, unit * 1.5 * scale),
      radius: unit * 6 * scale,
    );
    canvas.drawArc(
      smile,
      math.pi * 0.15,
      math.pi * 0.70,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2 * unit * scale
        ..color = line.color,
    );
  }

  @override
  bool shouldRepaint(_AvatarPainter old) =>
      old.kind != kind || old.selected != selected;
}
