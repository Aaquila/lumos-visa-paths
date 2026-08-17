import 'package:flutter/material.dart';

import '../../models/pathway_graph.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

// `DeadlineStub` used to live here: a boarding-pass card holding three
// hardcoded strings, borrowed by the dashboard to make the deadline tracker
// look real. The tracker is real now — see `models/deadline.dart`,
// `services/deadline_service.dart` and `widgets/deadline_card.dart` — so the
// fake is gone along with its `_Perforation` helper, which nothing else used.

/// A compact, non-interactive read of the real graph: the MVP spine plus the
/// marriage branch, drawn with the same node-card + route-line language as the
/// full `/visa-pathways` map.
class SpinePreview extends StatelessWidget {
  const SpinePreview({
    super.key,
    required this.graph,
    this.youAreHere,
    this.spine = defaultSpine,
    this.branchNodeId = defaultBranch,
  });

  final PathwayGraph graph;

  /// Node id to mark with the "you are here" pin.
  final String? youAreHere;

  /// The ordered chain of node ids to draw. Defaults to the illustrative F-1
  /// → OPT → H-1B → EB-2 → LPR spine; pass a real computed route to show a
  /// person's actual pathway instead.
  final List<String> spine;

  /// A dashed side-branch off [spine]'s first node, drawn only when set — the
  /// marriage illustration only makes sense alongside the default spine, not
  /// a real computed route.
  final String? branchNodeId;

  static const defaultSpine = <String>[
    'student.f1',
    'student.opt_postcompletion',
    'student.stem_opt',
    'temp_worker.h1b',
    'employment_gc.eb2',
    'post_lpr.lpr',
  ];
  static const defaultBranch = 'family_gc.marriage_aos';

  @override
  Widget build(BuildContext context) {
    // Fractional layout: the spine runs along the middle, the branch drops below.
    const spineY = 0.30;
    final branch = branchNodeId;
    final divisor = spine.length > 1 ? spine.length - 1 : 1;
    final points = <String, Offset>{
      for (var i = 0; i < spine.length; i++)
        spine[i]: Offset(0.06 + i * (0.88 / divisor), spineY),
      ?branch: const Offset(0.5, 0.78),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        Offset px(String id) => Offset(points[id]!.dx * w, points[id]!.dy * h);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            CustomPaint(
              size: Size(w, h),
              painter: _SpinePainter(
                spine: [for (final id in spine) px(id)],
                branchFrom: branch == null ? null : px(spine.first),
                branchTo: branch == null ? null : px(branch),
                branchOut: branch == null ? null : px(spine.last),
              ),
            ),
            for (final id in [...spine, ?branch])
              Positioned(
                left: px(id).dx - 58,
                top: px(id).dy - 21,
                child: _MiniNode(
                  label: graph.node(id)?.name ?? id,
                  current: id == youAreHere,
                  dimmed: id == branch,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MiniNode extends StatelessWidget {
  const _MiniNode({
    required this.label,
    this.current = false,
    this.dimmed = false,
  });

  final String label;
  final bool current;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.72 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (current)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.place, size: 13, color: T.signalBlue),
                  const SizedBox(width: 3),
                  Text(
                    'You are here',
                    style: AppTheme.caption.copyWith(
                      color: T.signalBlue,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          Container(
            width: 116,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: T.paper,
              border: Border.all(
                color: current ? T.signalBlue : T.pencilGray,
                width: current ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(T.rInput),
              boxShadow: current ? T.floatShadow : null,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.caption.copyWith(
                color: T.ink,
                fontWeight: FontWeight.w600,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpinePainter extends CustomPainter {
  _SpinePainter({
    required this.spine,
    required this.branchFrom,
    required this.branchTo,
    required this.branchOut,
  });

  final List<Offset> spine;
  final Offset? branchFrom;
  final Offset? branchTo;
  final Offset? branchOut;

  @override
  void paint(Canvas canvas, Size size) {
    final open = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = T.signalBlue;

    for (var i = 0; i < spine.length - 1; i++) {
      canvas.drawLine(
        spine[i] + const Offset(58, 0),
        spine[i + 1] - const Offset(58, 0),
        open,
      );
    }

    final branchFrom = this.branchFrom;
    final branchTo = this.branchTo;
    final branchOut = this.branchOut;
    if (branchFrom == null || branchTo == null || branchOut == null) return;

    // The "surprise branch": a curved life-event edge, drawn dashed and muted.
    final path = Path()
      ..moveTo(branchFrom.dx, branchFrom.dy + 21)
      ..cubicTo(
        branchFrom.dx,
        branchTo.dy,
        branchTo.dx - 90,
        branchTo.dy,
        branchTo.dx - 58,
        branchTo.dy,
      );
    final out = Path()
      ..moveTo(branchTo.dx + 58, branchTo.dy)
      ..cubicTo(
        branchTo.dx + 140,
        branchTo.dy,
        branchOut.dx,
        branchTo.dy,
        branchOut.dx,
        branchOut.dy + 21,
      );

    final dashed = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = T.pencilGray;
    for (final p in [path, out]) {
      _drawDashed(canvas, p, dashed);
    }
  }

  void _drawDashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + 7).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d = end + 6;
      }
    }
  }

  @override
  bool shouldRepaint(_SpinePainter old) =>
      old.spine != spine || old.branchTo != branchTo;
}
