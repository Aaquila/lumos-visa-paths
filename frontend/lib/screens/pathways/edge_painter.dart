import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/pathway_graph.dart';
import '../../theme/tokens.dart';

/// Draws every transition between statuses as a route line: solid Signal Blue
/// when it is part of the highlighted route, a thin grey hairline otherwise.
/// Backward edges (auto-upgrades, portability) loop under the row so they never
/// read as a forward step.
class EdgePainter extends CustomPainter {
  EdgePainter({
    required this.graph,
    required this.visible,
    required this.highlighted,
    required this.dimmed,
  });

  final PathwayGraph graph;

  /// Node ids currently rendered — edges to hidden nodes are skipped.
  final Set<String> visible;

  /// Edges touching this node are promoted to Signal Blue.
  final Set<String> highlighted;

  /// When true, non-highlighted edges fade back so the route reads clearly.
  final bool dimmed;

  static const _w = PathwayGraph.nodeWidth;
  static const _h = PathwayGraph.nodeHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Highlighted edges paint last so they sit on top of the grey mesh.
    final deferred = <PathwayEdge>[];

    for (final edge in graph.edges) {
      if (!visible.contains(edge.from) || !visible.contains(edge.to)) continue;
      final isHot =
          highlighted.contains(edge.from) || highlighted.contains(edge.to);
      if (isHot) {
        deferred.add(edge);
        continue;
      }
      _drawEdge(
        canvas,
        edge,
        // With ~80 edges on a wide canvas, the long backward routes cross a lot
        // of empty space. Once a node is selected they fade well back, so the
        // highlighted route reads against them rather than through them.
        base
          ..color = T.pencilGray.withValues(alpha: dimmed ? 0.12 : 0.42)
          ..strokeWidth = 1.2,
        arrowColor: T.pencilGray.withValues(alpha: dimmed ? 0.18 : 0.6),
      );
    }

    for (final edge in deferred) {
      _drawEdge(
        canvas,
        edge,
        base
          ..color = T.signalBlue
          ..strokeWidth = 2.2,
        arrowColor: T.signalBlue,
      );
    }
  }

  void _drawEdge(
    Canvas canvas,
    PathwayEdge edge,
    Paint paint, {
    required Color arrowColor,
  }) {
    final from = graph.positions[edge.from];
    final to = graph.positions[edge.to];
    if (from == null || to == null) return;

    if (edge.isSelfLoop) {
      // Portability: a loop over the top of the card.
      final cx = from.x + _w / 2;
      final top = from.y;
      final path = Path()
        ..moveTo(cx - 26, top)
        ..cubicTo(cx - 26, top - 42, cx + 26, top - 42, cx + 26, top);
      canvas.drawPath(path, paint);
      _arrow(canvas, Offset(cx + 26, top), math.pi / 2, arrowColor);
      return;
    }

    final start = Offset(from.x + _w, from.y + _h / 2);
    final end = Offset(to.x, to.y + _h / 2);

    final Path path;
    if (to.x > from.x) {
      // Forward: a horizontal S-curve.
      final dx = (end.dx - start.dx) * 0.45;
      path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(start.dx + dx, start.dy, end.dx - dx, end.dy, end.dx, end.dy);
      _arrow(canvas, end, 0, arrowColor);
    } else {
      // Backward or same-column: leave the left edge, swing below, come back.
      final s = Offset(from.x, from.y + _h / 2);
      final e = Offset(to.x + _w, to.y + _h / 2);
      final drop = math.max(s.dy, e.dy) + _h * 0.9;
      path = Path()
        ..moveTo(s.dx, s.dy)
        ..cubicTo(s.dx - 60, s.dy, s.dx - 60, drop, (s.dx + e.dx) / 2, drop)
        ..cubicTo(e.dx + 60, drop, e.dx + 60, e.dy, e.dx, e.dy);
      _arrow(canvas, e, math.pi, arrowColor);
    }
    if (edge.optional) {
      // Optional routes are drawn dashed: the step exists, but nothing forces
      // you through it.
      _drawDashed(canvas, path, paint);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  void _drawDashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = math.min(d + 8, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d = end + 6;
      }
    }
  }

  /// Small solid triangle at the target end; [rotation] is the incoming
  /// direction in radians (0 = pointing right).
  void _arrow(Canvas canvas, Offset tip, double rotation, Color color) {
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(rotation);
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(-7, -4)
      ..lineTo(-7, 4)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(EdgePainter old) =>
      old.highlighted != highlighted ||
      old.visible != visible ||
      old.dimmed != dimmed;
}
