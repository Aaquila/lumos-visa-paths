import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// One checkpoint on the hero journey rail.
class JourneyStop {
  const JourneyStop({
    required this.label,
    required this.caption,
    required this.icon,
    this.isDestination = false,
  });

  final String label;
  final String caption;
  final IconData icon;
  final bool isDestination;
}

const kDefaultJourney = <JourneyStop>[
  JourneyStop(label: 'F-1', caption: 'Student', icon: Icons.school_outlined),
  JourneyStop(label: 'OPT', caption: '12 months', icon: Icons.work_outline),
  JourneyStop(
    label: 'STEM OPT',
    caption: '+24 months',
    icon: Icons.science_outlined,
  ),
  JourneyStop(
    label: 'H-1B',
    caption: 'Cap lottery',
    icon: Icons.confirmation_number_outlined,
  ),
  JourneyStop(
    label: 'EB-2 / EB-3',
    caption: 'Green card',
    icon: Icons.badge_outlined,
    isDestination: true,
  ),
];

/// A cartoon traveller with luggage walking a visa route: she waits at an entry
/// point, walks to the next checkpoint, gets stamped, and moves on. The route
/// behind her is solid Signal Blue (travelled); the route ahead is a grey dashed
/// line (still to come).
class HeroJourney extends StatefulWidget {
  const HeroJourney({
    super.key,
    this.stops = kDefaultJourney,
    this.height = 260,
  });

  final List<JourneyStop> stops;
  final double height;

  @override
  State<HeroJourney> createState() => _HeroJourneyState();
}

class _HeroJourneyState extends State<HeroJourney>
    with SingleTickerProviderStateMixin {
  static const _dwell = 1.15; // seconds paused at a checkpoint
  static const _walk = 1.75; // seconds spent walking a segment

  late final AnimationController _controller;
  late final double _total;

  /// Icon glyphs are painted directly, so each one is laid out once and reused.
  final Map<IconData, TextPainter> _iconCache = {};
  final Map<String, TextPainter> _textCache = {};

  @override
  void initState() {
    super.initState();
    final segments = math.max(widget.stops.length - 1, 1);
    _total = widget.stops.length * _dwell + segments * _walk + 0.9;
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_total * 1000).round()),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      // Hold the final frame: the traveller stands at the destination and every
      // checkpoint is already stamped, so the whole route still reads — it just
      // does not loop. The information is in the end state, not the walk.
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final p in _iconCache.values) {
      p.dispose();
    }
    for (final p in _textCache.values) {
      p.dispose();
    }
    super.dispose();
  }

  /// The whole illustration is a canvas, so a screen reader would otherwise get
  /// nothing at all from it. This spells out the same route in words: the
  /// example journey and each checkpoint in order.
  String get _semanticLabel {
    final route = [
      for (final s in widget.stops) '${s.label}, ${s.caption}',
    ].join('; then ');
    return 'Illustration of an example visa route: $route. '
        'The full interactive map of every status is on the visa pathways page.';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Semantics(
        label: _semanticLabel,
        image: true,
        container: true,
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => CustomPaint(
                painter: _JourneyPainter(
                  stops: widget.stops,
                  t: _controller.value * _total,
                  dwell: _dwell,
                  walk: _walk,
                  iconCache: _iconCache,
                  textCache: _textCache,
                  textScale: MediaQuery.textScalerOf(context).scale(1),
                ),
                size: Size.infinite,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _JourneyPainter extends CustomPainter {
  _JourneyPainter({
    required this.stops,
    required this.t,
    required this.dwell,
    required this.walk,
    required this.iconCache,
    required this.textCache,
    required this.textScale,
  });

  final List<JourneyStop> stops;
  final double t;
  final double dwell;
  final double walk;
  final Map<IconData, TextPainter> iconCache;
  final Map<String, TextPainter> textCache;
  final double textScale;

  double _arrivalOf(int i) => i * (dwell + walk);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // ── Rail geometry ───────────────────────────────────────────────────────
    final scale = (size.width / 900).clamp(0.62, 1.0);
    // Wide enough that the outermost checkpoint labels ("EB-2 / EB-3") still
    // fit inside the card rather than clipping at its edge.
    final inset = 76.0 * scale + 16;
    // Extra room on the left so the traveller, who waits just short of each
    // checkpoint, still has clear ground at the very first one.
    final leftInset = inset + 76 * scale;
    final railY = size.height * 0.70;
    final span = size.width - leftInset - inset;
    final gap = stops.length > 1 ? span / (stops.length - 1) : 0.0;
    final xs = [for (var i = 0; i < stops.length; i++) leftInset + i * gap];

    // ── Where is she right now? ─────────────────────────────────────────────
    final lastArrival = _arrivalOf(stops.length - 1);
    var walker = xs.last;
    var walking = false;

    if (t < lastArrival + dwell) {
      final segment = (t / (dwell + walk)).floor().clamp(0, stops.length - 2);
      final into = t - _arrivalOf(segment);
      if (into <= dwell) {
        walker = xs[segment];
      } else {
        walking = true;
        final p = ((into - dwell) / walk).clamp(0.0, 1.0);
        // Ease in and out of each leg so she doesn't teleport into motion.
        final eased = Curves.easeInOutSine.transform(p);
        walker = ui.lerpDouble(xs[segment], xs[segment + 1], eased)!;
      }
    }

    // Stamp progress per checkpoint: 0 until she arrives, then a quick pop.
    final stamped = [
      for (var i = 0; i < stops.length; i++)
        ((t - _arrivalOf(i)) / 0.5).clamp(0.0, 1.0),
    ];

    _paintRail(canvas, xs, railY, walker, scale);
    for (var i = 0; i < stops.length; i++) {
      _paintStop(canvas, xs[i], railY, stops[i], stamped[i], scale);
    }
    // She stands just short of each checkpoint rather than under its pin, so
    // the stamp stays readable while she waits there.
    _paintTraveller(canvas, walker - 64 * scale, railY, scale, walking);
  }

  // ── Route line ────────────────────────────────────────────────────────────

  void _paintRail(
    Canvas canvas,
    List<double> xs,
    double y,
    double walker,
    double scale,
  ) {
    final ahead = Paint()
      ..color = T.pencilGray.withValues(alpha: 0.55)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Dashed remainder of the route.
    const dash = 9.0;
    const hole = 8.0;
    var x = walker;
    while (x < xs.last) {
      final end = math.min(x + dash, xs.last);
      canvas.drawLine(Offset(x, y), Offset(end, y), ahead);
      x = end + hole;
    }

    // Travelled portion, solid Signal Blue.
    canvas.drawLine(
      Offset(xs.first, y),
      Offset(walker, y),
      Paint()
        ..color = T.signalBlue
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  // ── Checkpoints ───────────────────────────────────────────────────────────

  void _paintStop(
    Canvas canvas,
    double x,
    double railY,
    JourneyStop stop,
    double progress,
    double scale,
  ) {
    final r = 21.0 * scale;
    // The checkpoint sits above the route as a pin on a stem, leaving the line
    // itself clear for the traveller to walk along.
    final y = railY - 34 * scale;
    final active = progress > 0;

    canvas.drawLine(
      Offset(x, y + r),
      Offset(x, railY),
      Paint()
        ..strokeWidth = 1.4
        ..color = active ? T.signalBlue : T.pencilGray,
    );
    canvas.drawCircle(
      Offset(x, railY),
      3.2,
      Paint()..color = active ? T.signalBlue : T.pencilGray,
    );

    // Arrival ripple — a ring that expands and fades once, on stamping.
    if (progress > 0 && progress < 1) {
      canvas.drawCircle(
        Offset(x, y),
        r + 16 * progress,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = T.skyWash.withValues(alpha: (1 - progress) * 0.9),
      );
    }

    // A small pop on landing, settling back to rest.
    final pop = progress == 0
        ? 1.0
        : 1 + 0.16 * math.sin(math.min(progress, 1.0) * math.pi);

    canvas.save();
    canvas.translate(x, y);
    canvas.scale(pop);

    canvas.drawCircle(Offset.zero, r, Paint()..color = T.paper);
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2 : 1
        ..color = active ? T.signalBlue : T.pencilGray,
    );
    if (active) {
      canvas.drawCircle(
        Offset.zero,
        r - 1,
        Paint()..color = T.signalBlue.withValues(alpha: 0.10 * progress),
      );
    }

    _icon(
      stop.icon,
      19 * scale,
      active ? T.signalBlue : T.pencilGray,
    ).paint(canvas, Offset(-9.5 * scale, -9.5 * scale));

    canvas.restore();

    // Approved tick, once fully stamped.
    if (progress >= 1) {
      final badge = Offset(x + r * 0.72, y - r * 0.72);
      canvas.drawCircle(badge, 8 * scale, Paint()..color = T.signalBlue);
      _icon(
        Icons.check,
        11 * scale,
        T.paper,
      ).paint(canvas, badge + Offset(-5.5 * scale, -5.5 * scale));
    }

    // Destination flag.
    if (stop.isDestination) {
      _icon(
        Icons.flag,
        15 * scale,
        progress >= 1 ? T.signalBlue : T.pencilGray,
      ).paint(canvas, Offset(x - 7.5 * scale, y - r - 26 * scale));
    }

    // Labels below the route line.
    _text(
      stop.label,
      size: 14 * scale,
      weight: FontWeight.w600,
      color: active ? T.ink : T.graphite,
    ).paintCentered(canvas, Offset(x, railY + 14 * scale));

    // Graphite, not Pencil Gray: at 11.5px this is body-sized text and has to
    // clear 4.5:1 (Pencil Gray on white is 2.84:1).
    _text(
      stop.caption,
      size: 11.5 * scale,
      weight: FontWeight.w400,
      color: T.graphite,
    ).paintCentered(canvas, Offset(x, railY + 32 * scale));
  }

  // ── The traveller ─────────────────────────────────────────────────────────

  /// Feet sit at the origin; everything else is drawn upward in -y.
  void _paintTraveller(
    Canvas canvas,
    double x,
    double railY,
    double scale,
    bool walking,
  ) {
    final stride = walking ? math.sin(t * 9.5) : 0.0;
    final bob = walking
        ? (math.sin(t * 19) * 1.4 - 1.4)
        : math.sin(t * 2.2) * 0.8;

    canvas.save();
    canvas.translate(x, railY - 4 * scale);
    canvas.scale(scale * 0.92);

    // Ground shadow — squashes as she rises on each step.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(0, 6),
        width: 40 - bob.abs() * 2,
        height: 9,
      ),
      Paint()..color = T.ink.withValues(alpha: 0.07),
    );

    canvas.translate(0, bob);
    // A touch of forward lean while in motion.
    canvas.rotate(walking ? 0.03 : 0.0);

    final skin = const Color(0xFFF5CDA7);
    final coat = T.signalBlue;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = T.ink
      ..strokeJoin = StrokeJoin.round;

    // ── Legs ────────────────────────────────────────────────────────────────
    void leg(double swing, Color color) {
      final hip = const Offset(-1, -30);
      final knee = Offset(hip.dx + swing * 7, hip.dy + 15);
      final foot = Offset(hip.dx + swing * 15, hip.dy + 30);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawPath(
        Path()
          ..moveTo(hip.dx, hip.dy)
          ..lineTo(knee.dx, knee.dy)
          ..lineTo(foot.dx, foot.dy),
        paint,
      );
      // Shoe.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(foot.dx - 3.5, foot.dy - 2.5, 12, 5.5),
          const Radius.circular(3),
        ),
        Paint()..color = T.ink,
      );
    }

    leg(-stride, const Color(0xFF3A4A5C)); // back leg, slightly darker
    leg(stride, const Color(0xFF4B5D71));

    // ── Backpack ────────────────────────────────────────────────────────────
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-19, -55, 13, 22),
        const Radius.circular(5),
      ),
      Paint()..color = T.pastelPeach,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-19, -55, 13, 22),
        const Radius.circular(5),
      ),
      outline,
    );
    canvas.drawLine(
      const Offset(-19, -47),
      const Offset(-6, -47),
      Paint()
        ..color = T.ink
        ..strokeWidth = 1.5,
    );

    // ── Torso ───────────────────────────────────────────────────────────────
    final torso = RRect.fromRectAndCorners(
      const Rect.fromLTWH(-11, -58, 22, 30),
      topLeft: const Radius.circular(9),
      topRight: const Radius.circular(9),
      bottomLeft: const Radius.circular(4),
      bottomRight: const Radius.circular(4),
    );
    canvas.drawRRect(torso, Paint()..color = coat);
    canvas.drawRRect(torso, outline);
    // Coat placket.
    canvas.drawLine(
      const Offset(2, -56),
      const Offset(2, -30),
      Paint()
        ..color = T.paper.withValues(alpha: 0.55)
        ..strokeWidth = 1.5,
    );

    // ── Head ────────────────────────────────────────────────────────────────
    const head = Offset(1.5, -68);
    canvas.drawCircle(head, 10.5, Paint()..color = skin);
    canvas.drawCircle(head, 10.5, outline);
    // Hair: a cap arc plus a bun, facing right.
    canvas.drawPath(
      Path()
        ..moveTo(head.dx - 11, head.dy + 1)
        ..arcToPoint(
          Offset(head.dx + 9.5, head.dy - 3),
          radius: const Radius.circular(11),
        )
        ..lineTo(head.dx + 6, head.dy - 6)
        ..lineTo(head.dx - 11, head.dy - 4)
        ..close(),
      Paint()..color = const Color(0xFF2B2118),
    );
    canvas.drawCircle(
      Offset(head.dx - 11, head.dy - 3),
      4.5,
      Paint()..color = const Color(0xFF2B2118),
    );
    // Eye + smile.
    canvas.drawCircle(
      Offset(head.dx + 4.5, head.dy),
      1.6,
      Paint()..color = T.ink,
    );
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(head.dx + 3.5, head.dy + 3),
        width: 7,
        height: 6,
      ),
      0.15,
      2.4,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..color = T.ink,
    );

    // ── Arm + rolling suitcase ──────────────────────────────────────────────
    // The case swings a little out of phase with her stride.
    final caseLift = walking ? math.sin(t * 9.5 + 0.9) * 1.2 : 0.0;
    final hand = Offset(19, -40 + caseLift);

    canvas.drawPath(
      Path()
        ..moveTo(9, -53)
        ..quadraticBezierTo(17, -49, hand.dx, hand.dy),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..color = coat,
    );
    canvas.drawCircle(hand, 3.4, Paint()..color = skin);
    canvas.drawCircle(hand, 3.4, outline..strokeWidth = 1.5);

    // Telescoping handle.
    canvas.drawPath(
      Path()
        ..moveTo(hand.dx, hand.dy)
        ..lineTo(28, hand.dy)
        ..lineTo(28, -30 + caseLift),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = T.ink,
    );

    // Case body.
    final caseRect = Rect.fromLTWH(19, -30 + caseLift, 21, 24);
    canvas.drawRRect(
      RRect.fromRectAndRadius(caseRect, const Radius.circular(5)),
      Paint()..color = T.pastelYellow,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(caseRect, const Radius.circular(5)),
      outline..strokeWidth = 2,
    );
    // Strap + a travel sticker.
    canvas.drawLine(
      Offset(caseRect.left, caseRect.top + 9),
      Offset(caseRect.right, caseRect.top + 9),
      Paint()
        ..color = T.ink
        ..strokeWidth = 1.6,
    );
    canvas.drawCircle(
      Offset(caseRect.left + 6, caseRect.bottom - 6),
      3,
      Paint()..color = T.pastelPink,
    );
    // Wheels.
    for (final wx in [caseRect.left + 5, caseRect.right - 5]) {
      canvas.drawCircle(
        Offset(wx, caseRect.bottom + 1.5),
        2.6,
        Paint()..color = T.ink,
      );
    }

    canvas.restore();
  }

  // ── Text/icon helpers ─────────────────────────────────────────────────────

  TextPainter _icon(IconData icon, double size, Color color) {
    final key = icon;
    final cached = iconCache[key];
    // Size/colour change with layout, so re-layout rather than trusting cache
    // blindly; the cache still saves the allocation.
    final painter = cached ?? TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: size,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: color,
      ),
    );
    painter.layout();
    iconCache[key] = painter;
    return painter;
  }

  _CenteredText _text(
    String value, {
    required double size,
    required FontWeight weight,
    required Color color,
  }) {
    final key = '$value|$size|${weight.value}|${color.toARGB32()}';
    final painter =
        textCache[key] ??
        (textCache[key] = TextPainter(textDirection: TextDirection.ltr));
    painter.text = TextSpan(
      text: value,
      style: AppTheme.inter(
        size,
        weight: weight,
        color: color,
        tracking: -0.2 / size,
      ),
    );
    painter.textScaler = TextScaler.linear(textScale);
    painter.layout();
    return _CenteredText(painter);
  }

  @override
  bool shouldRepaint(_JourneyPainter old) => old.t != t || old.stops != stops;
}

extension type _CenteredText(TextPainter painter) {
  void paintCentered(Canvas canvas, Offset center) =>
      painter.paint(canvas, Offset(center.dx - painter.width / 2, center.dy));
}
