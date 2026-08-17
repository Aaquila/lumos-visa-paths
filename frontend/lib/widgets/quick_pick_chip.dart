import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A tappable shortcut next to a free-text box.
///
/// Chips here are always optional and never the only way to answer — they
/// exist so somebody who already knows the label can skip the typing, not so
/// the app can insist on a form-coded answer. Tapping a selected chip clears
/// it, so a mis-tap costs one tap to undo.
class QuickPickChip extends StatefulWidget {
  const QuickPickChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<QuickPickChip> createState() => _QuickPickChipState();
}

class _QuickPickChipState extends State<QuickPickChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            // 44px of height even at the default text size — these sit in a
            // wrap and must not become a minefield of small targets.
            constraints: const BoxConstraints(minHeight: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? T.skyWash.withValues(alpha: 0.55)
                  : (_hover ? const Color(0xFFF5F7F9) : T.paper),
              border: Border.all(
                color: widget.selected || _hover ? T.signalBlue : T.pencilGray,
                width: widget.selected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(T.rPill),
            ),
            child: Text(
              widget.label,
              style: AppTheme.label.copyWith(
                color: widget.selected ? T.ink : T.carbon,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
