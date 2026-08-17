import 'package:flutter/material.dart';

import '../models/evidence.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The four-way self-assessment control.
///
/// Deliberately stacked rather than a row of chips: each option carries a line
/// of explanation, and "Not started" is listed first and worded so it reads as
/// a normal starting point rather than a failure.
class EvidenceStrengthPicker extends StatelessWidget {
  const EvidenceStrengthPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final EvidenceStrength value;
  final ValueChanged<EvidenceStrength> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final option in EvidenceStrength.values) ...[
          _Option(
            option: option,
            selected: option == value,
            onTap: () => onChanged(option),
          ),
          if (option != EvidenceStrength.values.last)
            const SizedBox(height: T.s8),
        ],
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final EvidenceStrength option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: '${option.label}. ${option.blurb}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.all(T.s16),
            decoration: BoxDecoration(
              color: selected ? T.pastelSky.withValues(alpha: 0.5) : T.paper,
              borderRadius: BorderRadius.circular(T.rInput),
              border: Border.all(
                color: selected ? T.signalBlue : T.pencilGray,
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? T.signalBlue : T.pencilGray,
                ),
                const SizedBox(width: T.s16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        style: AppTheme.label.copyWith(
                          fontWeight: FontWeight.w600,
                          color: T.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(option.blurb, style: AppTheme.caption),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The small read-only marker used in lists.
class EvidenceStrengthDot extends StatelessWidget {
  const EvidenceStrengthDot({super.key, required this.strength});

  final EvidenceStrength strength;

  static Color colorFor(EvidenceStrength s) => switch (s) {
    EvidenceStrength.notStarted => T.pencilGray,
    EvidenceStrength.inProgress => T.pastelPeach,
    EvidenceStrength.haveEvidence => T.skyWash,
    EvidenceStrength.strong => T.signalBlue,
  };

  @override
  Widget build(BuildContext context) {
    final filled = strength != EvidenceStrength.notStarted;
    return Tooltip(
      message: strength.label,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? colorFor(strength) : T.paper,
          border: Border.all(color: colorFor(strength), width: 1.4),
        ),
      ),
    );
  }
}
