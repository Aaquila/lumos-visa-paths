import 'package:flutter/material.dart';

import '../models/evidence.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// One category's standing, on the overview.
///
/// There is no percentage and no grade. The bar is progress made, the headline
/// states the gap in words, and a person with nothing recorded is told that is
/// where most people start — because it is, and because a screen about
/// immigration should not read as a rejection letter.
class EvidenceReadinessCard extends StatelessWidget {
  const EvidenceReadinessCard({
    super.key,
    required this.set,
    required this.readiness,
    required this.onOpen,
  });

  final EvidenceSet set;
  final EvidenceReadiness readiness;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(T.cardPadding),
          decoration: BoxDecoration(
            color: T.paper,
            borderRadius: BorderRadius.circular(T.rCard),
            border: Border.fromBorderSide(T.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      set.visaCode,
                      style: AppTheme.headingSm.copyWith(fontSize: 20),
                    ),
                  ),
                  _StructureChip(structure: readiness.structure),
                ],
              ),
              const SizedBox(height: 6),
              Text(set.title, style: AppTheme.caption),
              const SizedBox(height: T.s16),
              EvidenceProgressBar(value: readiness.progress),
              const SizedBox(height: T.s16),
              Text(
                readiness.hasStarted
                    ? readiness.headline
                    : 'Nothing recorded yet.',
                style: AppTheme.label.copyWith(color: T.ink),
              ),
              const SizedBox(height: 6),
              Text(
                readiness.hasStarted
                    ? readiness.detail
                    : readiness.encouragement,
                style: AppTheme.bodySm,
              ),
              const SizedBox(height: T.s16),
              Row(
                children: [
                  Text(
                    readiness.hasStarted ? 'Continue' : 'Start here',
                    style: AppTheme.label.copyWith(color: T.signalBlue),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.arrow_forward,
                    size: 15,
                    color: T.signalBlue,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Progress made, not a score out of anything.
class EvidenceProgressBar extends StatelessWidget {
  const EvidenceProgressBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(T.rPill),
      child: SizedBox(
        height: 8,
        child: Stack(
          children: [
            Container(color: T.skyWash.withValues(alpha: 0.45)),
            FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                color: T.signalBlue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Names the shape of the category, so nobody assumes "three out of ten"
/// everywhere.
class _StructureChip extends StatelessWidget {
  const _StructureChip({required this.structure});

  final EvidenceStructure structure;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (structure) {
      EvidenceStructure.criteriaCount => ('Criteria count', T.pastelMint),
      EvidenceStructure.criteriaCountWithFinalMerits => (
        'Two-step',
        T.pastelLavender,
      ),
      EvidenceStructure.gatedCriteria => ('Requirements first', T.pastelPeach),
      EvidenceStructure.qualifyingConditions => ('Checklist', T.pastelPink),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(T.rPill),
      ),
      child: Text(label, style: AppTheme.badge),
    );
  }
}

/// A suggested next move, shown one or two at a time.
class EvidenceNextActionCard extends StatelessWidget {
  const EvidenceNextActionCard({
    super.key,
    required this.action,
    required this.onOpen,
    this.showSetCode,
  });

  final EvidenceNextAction action;
  final VoidCallback onOpen;

  /// Set on the overview, where actions come from several categories.
  final String? showSetCode;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(T.s24),
          decoration: BoxDecoration(
            color: T.pastelMint.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(T.rCard),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt_outlined, size: 16, color: T.ink),
                  const SizedBox(width: 8),
                  Text(
                    showSetCode == null
                        ? 'Highest leverage next'
                        : '${showSetCode!} · highest leverage next',
                    style: AppTheme.badge,
                  ),
                ],
              ),
              const SizedBox(height: T.s8),
              Text(
                action.item.name,
                style: AppTheme.label.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: T.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(action.rationale, style: AppTheme.bodySm),
              if (action.item.timeToBuild.isNotEmpty) ...[
                const SizedBox(height: T.s8),
                Text(action.item.timeToBuild, style: AppTheme.caption),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
