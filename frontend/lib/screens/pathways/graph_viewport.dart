import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A pan-and-zoom viewport for the pathway canvas.
///
/// This replaces `InteractiveViewer` deliberately. The canvas is covered edge to
/// edge in node cards that carry their own tap and hover handlers, and the
/// combination left drag-to-pan unreliable — you could zoom but not reliably
/// drag. Owning the gesture here makes panning work anywhere on the canvas,
/// including on top of a card, while a tap that never moves still selects it.
///
/// Controls:
///  * drag anywhere (mouse, touch, trackpad) → pan
///  * pinch → zoom about the pinch centre
///  * mouse wheel / two-finger scroll → zoom about the pointer
///  * shift + wheel → pan horizontally
///  * trackpad pinch on web (which the browser reports as ctrl + wheel, and
///    Flutter forwards as a [PointerScaleEvent]) → zoom about the pointer
///
/// Drive the buttons in the page chrome through the [GraphViewportState] API
/// ([GraphViewportState.zoomBy], [GraphViewportState.fit],
/// [GraphViewportState.focusOn]) rather than writing to the
/// [TransformationController] directly, so every path shares the same scale and
/// translation clamping.
class GraphViewport extends StatefulWidget {
  const GraphViewport({
    super.key,
    required this.controller,
    required this.canvasSize,
    required this.child,
    this.minScale = 0.4,
    this.maxScale = 2.5,
    this.onInteractionEnd,
  });

  final TransformationController controller;
  final Size canvasSize;
  final Widget child;
  final double minScale;
  final double maxScale;

  /// Called after anything moves the viewport, so the host can repaint chrome
  /// such as the zoom percentage read-out.
  final VoidCallback? onInteractionEnd;

  @override
  State<GraphViewport> createState() => GraphViewportState();
}

class GraphViewportState extends State<GraphViewport> {
  /// How far outside its natural range the canvas may be pushed, so a node at
  /// the edge can still be dragged into the middle of the screen. Bounded so
  /// the graph can never be flicked entirely off-screen.
  static const _slack = 280.0;

  /// Wheel notches are ~100px; this turns that into roughly a 1.16× step.
  static const _wheelZoomPerPixel = 0.0015;

  bool _dragging = false;
  Offset _lastFocal = Offset.zero;
  double _scaleAtGestureStart = 1;

  /// The current zoom factor.
  double get scale => widget.controller.value.getMaxScaleOnAxis();

  Offset get _translation {
    final m = widget.controller.value;
    return Offset(m.storage[12], m.storage[13]);
  }

  Size get _viewport {
    final box = context.findRenderObject() as RenderBox?;
    return box?.hasSize == true ? box!.size : Size.zero;
  }

  // ── Transform plumbing ────────────────────────────────────────────────────

  /// Keeps the canvas overlapping the viewport on both axes: it may be pushed
  /// [_slack] past the point where it would leave the screen, and no further.
  static double _clampAxis(double t, double viewLength, double contentLength) {
    final rest = viewLength - contentLength;
    return t.clamp(math.min(rest, 0) - _slack, math.max(rest, 0) + _slack);
  }

  void _setTransform(Offset translation, double newScale) {
    final clampedScale = newScale.clamp(widget.minScale, widget.maxScale);
    final view = _viewport;

    var dx = translation.dx;
    var dy = translation.dy;
    if (view != Size.zero) {
      dx = _clampAxis(dx, view.width, widget.canvasSize.width * clampedScale);
      dy = _clampAxis(dy, view.height, widget.canvasSize.height * clampedScale);
    }

    widget.controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(clampedScale, clampedScale, 1, 1);
  }

  /// Zoom by [factor] while keeping the scene point under [focal] fixed.
  void _zoomAround(Offset focal, double factor) {
    if (!factor.isFinite || factor <= 0) return;
    final current = scale;
    final next = (current * factor).clamp(widget.minScale, widget.maxScale);
    if (next == current) return;
    final translation = _translation;
    // scenePoint = (focal - translation) / current, and we want it to land back
    // under `focal` at the new scale.
    final scene = (focal - translation) / current;
    _setTransform(focal - scene * next, next);
  }

  void _panBy(Offset delta) => _setTransform(_translation + delta, scale);

  // ── Public API for the page chrome ────────────────────────────────────────

  /// Zoom about the centre of the viewport — what the +/− buttons call.
  void zoomBy(double factor) {
    final view = _viewport;
    if (view == Size.zero) return;
    _zoomAround(view.center(Offset.zero), factor);
    widget.onInteractionEnd?.call();
  }

  /// Scale the whole canvas to fit and centre it.
  void fit() {
    final view = _viewport;
    if (view == Size.zero ||
        widget.canvasSize.width <= 0 ||
        widget.canvasSize.height <= 0) {
      return;
    }
    // A little breathing room so edge cards are not flush with the frame.
    const padding = 32.0;
    final fitted = math.min<double>(
      (view.width - padding * 2) / widget.canvasSize.width,
      (view.height - padding * 2) / widget.canvasSize.height,
    );
    final double target = fitted.clamp(
      widget.minScale,
      math.min<double>(1.0, widget.maxScale),
    );
    _setTransform(
      Offset(
        (view.width - widget.canvasSize.width * target) / 2,
        (view.height - widget.canvasSize.height * target) / 2,
      ),
      target,
    );
    widget.onInteractionEnd?.call();
  }

  /// Put [scenePoint] (canvas coordinates) in the middle of the viewport.
  void focusOn(Offset scenePoint, {double? targetScale}) {
    final view = _viewport;
    if (view == Size.zero) return;
    final double next = (targetScale ?? scale).clamp(
      widget.minScale,
      widget.maxScale,
    );
    _setTransform(view.center(Offset.zero) - scenePoint * next, next);
    widget.onInteractionEnd?.call();
  }

  // ── Pointer signals (wheel, trackpad) ─────────────────────────────────────

  void _onPointerSignal(PointerSignalEvent event) {
    // A trackpad pinch on web arrives as a scale signal, not a scroll.
    if (event is PointerScaleEvent) {
      _zoomAround(event.localPosition, event.scale);
      widget.onInteractionEnd?.call();
      return;
    }
    if (event is! PointerScrollEvent) return;

    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift is the browser convention for "scroll sideways".
      final delta = event.scrollDelta;
      _panBy(Offset(-(delta.dx != 0 ? delta.dx : delta.dy), 0));
    } else {
      // Wheel and two-finger scroll zoom about the cursor. This is the primary
      // desktop-web interaction, so it needs no modifier key; ctrl/⌘ + wheel
      // does the same thing for people who expect the browser convention.
      _zoomAround(
        event.localPosition,
        math.exp(-event.scrollDelta.dy * _wheelZoomPerPixel),
      );
    }
    widget.onInteractionEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: MouseRegion(
        cursor: _dragging
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Scale gestures cover one-finger drag as well as pinch, so a single
          // recogniser handles both. A tap with no movement still loses the
          // arena to the node card underneath.
          onScaleStart: (details) {
            setState(() => _dragging = true);
            _lastFocal = details.localFocalPoint;
            _scaleAtGestureStart = scale;
          },
          onScaleUpdate: (details) {
            final focal = details.localFocalPoint;
            if (details.scale != 1.0) {
              // Pinch: apply the scale delta about the pinch centre…
              final target = _scaleAtGestureStart * details.scale;
              _zoomAround(focal, target / scale);
            }
            // …and always carry the focal-point movement as a pan.
            _panBy(focal - _lastFocal);
            _lastFocal = focal;
          },
          onScaleEnd: (_) {
            setState(() => _dragging = false);
            widget.onInteractionEnd?.call();
          },
          child: ClipRect(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => Transform(
                transform: widget.controller.value,
                alignment: Alignment.topLeft,
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: 0,
                  minHeight: 0,
                  maxWidth: double.infinity,
                  maxHeight: double.infinity,
                  child: SizedBox(
                    width: widget.canvasSize.width,
                    height: widget.canvasSize.height,
                    child: widget.child,
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
