import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

enum PillVariant {
  /// Signal Blue fill, white text — the one conversion action per page.
  signal,

  /// Ink fill, white text — nav primary.
  ink,

  /// Transparent with a 1px Pencil Gray hairline — every secondary action.
  outline,
}

/// A 2px Signal Blue ring, drawn *outside* the control so it never resizes it
/// or shifts anything around it — the focused element has to be obvious without
/// the layout moving underneath a keyboard user.
///
/// [onFill] swaps the ring to Ink, because Signal Blue drawn against a Signal
/// Blue fill is not a visible ring at all.
List<BoxShadow> focusRing({bool onFill = false}) => [
  BoxShadow(
    color: onFill ? T.ink : T.signalBlue,
    spreadRadius: 3,
    blurRadius: 0,
  ),
];

/// Every interactive control in this system is a full pill (1600px radius).
class PillButton extends StatefulWidget {
  const PillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = PillVariant.outline,
    this.icon,
    this.trailingIcon,
    this.large = false,
    this.glow = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final PillVariant variant;
  final IconData? icon;
  final IconData? trailingIcon;
  final bool large;

  /// Sky Wash glow — reserved for the hero CTA.
  final bool glow;
  final bool busy;

  @override
  State<PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<PillButton> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;

    final (Color bg, Color fg, BoxBorder? border) = switch (widget.variant) {
      PillVariant.signal => (
        _hover ? const Color(0xFF0070E0) : T.signalBlue,
        T.paper,
        null,
      ),
      PillVariant.ink => (_hover ? T.carbon : T.ink, T.paper, null),
      PillVariant.outline => (
        _hover ? const Color(0xFFF5F7F9) : Colors.transparent,
        T.carbon,
        Border.fromBorderSide(T.hairline),
      ),
    };

    final textStyle = AppTheme.label.copyWith(
      color: fg,
      fontSize: widget.large ? 18 : 14,
      fontWeight: widget.large ? FontWeight.w600 : FontWeight.w500,
      letterSpacing: widget.large ? -0.36 : -0.14,
    );

    return Semantics(
      button: true,
      enabled: enabled,
      // The label is the only thing a screen reader gets — the leading and
      // trailing icons are decoration on top of it, so they stay excluded
      // rather than being read as separate nodes.
      label: widget.busy ? '${widget.label}, busy' : widget.label,
      onTap: enabled ? widget.onPressed : null,
      // FocusableActionDetector rather than a bare MouseRegion +
      // GestureDetector: it is what makes the button Tab-reachable and
      // Enter/Space-activatable. Before this, every pill in the app was
      // pointer-only.
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          // Semantics are declared by the Semantics wrapper above this
          // control; without this the detector emits a second, unlabelled
          // tappable node beside it.
          excludeFromSemantics: true,
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: Motion.duration(
              context,
              const Duration(milliseconds: 160),
            ),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(
              horizontal: widget.large ? T.s32 : 20,
              vertical: widget.large ? T.s16 : T.s8,
            ),
            decoration: BoxDecoration(
              color: enabled ? bg : bg.withValues(alpha: 0.45),
              border: border,
              borderRadius: BorderRadius.circular(T.rPill),
              boxShadow: _focused
                  ? focusRing(onFill: widget.variant != PillVariant.outline)
                  : (widget.glow ? T.ctaGlow : null),
            ),
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.busy)
                    Padding(
                      padding: const EdgeInsets.only(right: T.s8),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(fg),
                        ),
                      ),
                    )
                  else if (widget.icon != null) ...[
                    Icon(widget.icon, size: widget.large ? 20 : 16, color: fg),
                    const SizedBox(width: T.s8),
                  ],
                  // Flexible so a long label or an enlarged browser font size
                  // wraps inside the pill instead of overflowing it. The pill
                  // is still MainAxisSize.min, so short labels are unaffected.
                  Flexible(child: Text(widget.label, style: textStyle)),
                  if (widget.trailingIcon != null) ...[
                    const SizedBox(width: T.s8),
                    AnimatedSlide(
                      duration: Motion.duration(
                        context,
                        const Duration(milliseconds: 160),
                      ),
                      offset: Offset(
                        _hover && !Motion.reduced(context) ? 0.25 : 0,
                        0,
                      ),
                      child: Icon(
                        widget.trailingIcon,
                        size: widget.large ? 18 : 12,
                        color: fg,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
