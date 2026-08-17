import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/case_profile.dart';
import '../models/deadline.dart';
import '../models/onboarding_profile.dart';
import '../models/pathway_graph.dart';
import '../services/deadline_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'add_deadline_sheet.dart';
import 'deadline_card.dart';

/// The dashboard's deadline block: the real list, derived and sorted.
///
/// Shows at most [maxVisible] items — the nearest one as a full card, the rest
/// compact — with everything else behind a link to `/deadlines`. That cap is
/// the point of the widget: an honest list of everything a person on OPT has to
/// think about is long enough to be paralysing, and a dashboard that paralyses
/// is worse than one that lies.
class DeadlinePanel extends StatefulWidget {
  const DeadlinePanel({
    super.key,
    required this.situation,
    required this.profile,
    required this.graph,
    this.maxVisible = 3,
    this.now,
  });

  final VisaSituation? situation;
  final CaseProfile? profile;
  final PathwayGraph? graph;
  final int maxVisible;

  /// Injected only by tests; production reads the real clock once per build.
  final DateTime? now;

  @override
  State<DeadlinePanel> createState() => _DeadlinePanelState();
}

class _DeadlinePanelState extends State<DeadlinePanel> {
  @override
  void initState() {
    super.initState();
    DeadlineService.instance.load();
  }

  Future<void> _add(DateTime now) async {
    final created = await showAddDeadlineSheet(context, now: now);
    if (created != null) await DeadlineService.instance.add(created);
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now ?? DateTime.now();
    final service = DeadlineService.instance;

    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final items = service.visible(
          situation: widget.situation,
          profile: widget.profile,
          graph: widget.graph,
          now: now,
        );

        if (items.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DeadlineEmptyState(
                hasSituation: widget.situation?.hasStatus ?? false,
                onSetUp: () => context.go('/onboarding/situation'),
                onAdd: () => _add(now),
              ),
              const SizedBox(height: T.s16),
              const _Disclaimer(),
            ],
          );
        }

        final shown = items.take(widget.maxVisible).toList();
        final rest = items.length - shown.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) const SizedBox(height: T.s8),
              DeadlineCard(
                deadline: shown[i],
                now: now,
                // One item dominates. Everything below it is deliberately quiet.
                lead: i == 0,
              ),
            ],
            const SizedBox(height: T.s16),
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                if (rest > 0)
                  _Link(
                    label: 'Show all $rest more',
                    icon: Icons.expand_more,
                    onPressed: () => context.go('/deadlines'),
                  )
                else
                  _Link(
                    label: 'Manage my dates',
                    icon: Icons.tune,
                    onPressed: () => context.go('/deadlines'),
                  ),
                _Link(
                  label: 'Add a date',
                  icon: Icons.add,
                  onPressed: () => _add(now),
                ),
              ],
            ),
            const SizedBox(height: T.s16),
            const _Disclaimer(),
          ],
        );
      },
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(T.rNav),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: T.signalBlue),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppTheme.bodySm.copyWith(
                color: T.signalBlue,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) =>
      Text(Deadline.disclaimer, style: AppTheme.caption);
}
