import 'package:flutter/material.dart';

import '../models/deadline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The visual language for a deadline.
///
/// There is no red anywhere in here, and that is deliberate. A red alarm on an
/// immigration date does not make anybody file faster; it makes them close the
/// tab. Nearness is carried by weight and a soft accent instead: the nearest
/// item gets a filled badge and a heavier border, everything else stays quiet.
/// Nothing on this surface says "late" in a tone that implies fault.
class DeadlineTone {
  const DeadlineTone._();

  static Color accent(DeadlineUrgency u) => switch (u) {
    // Past-its-date is amber-ish warm, not alarm red.
    DeadlineUrgency.overdue => const Color(0xFFB06A2C),
    DeadlineUrgency.thisWeek => T.signalBlue,
    DeadlineUrgency.thisMonth => T.voltageViolet,
    DeadlineUrgency.later => T.graphite,
    DeadlineUrgency.unknown => T.graphite,
  };

  static Color fill(DeadlineUrgency u) => switch (u) {
    DeadlineUrgency.overdue => T.pastelPeach,
    DeadlineUrgency.thisWeek => T.pastelSky,
    DeadlineUrgency.thisMonth => T.pastelLavender,
    DeadlineUrgency.later => T.pastelMint,
    DeadlineUrgency.unknown => T.pastelYellow,
  };

  static IconData icon(DeadlineUrgency u) => switch (u) {
    DeadlineUrgency.overdue => Icons.history,
    DeadlineUrgency.thisWeek => Icons.event_available_outlined,
    DeadlineUrgency.thisMonth => Icons.calendar_month_outlined,
    DeadlineUrgency.later => Icons.schedule,
    DeadlineUrgency.unknown => Icons.help_outline,
  };
}

/// One deadline, as a card.
///
/// [lead] makes it the single dominant item on the page: bigger type, the
/// consequence and the next action always visible. Every other card keeps the
/// same information but folds the detail away, so a list of five never becomes
/// a wall of text.
class DeadlineCard extends StatelessWidget {
  const DeadlineCard({
    super.key,
    required this.deadline,
    required this.now,
    this.lead = false,
    this.onDismiss,
    this.onSnooze,
    this.onRemove,
    this.trailing,
  });

  final Deadline deadline;
  final DateTime now;
  final bool lead;

  /// Null hides the control entirely — used for the anchor items that must not
  /// be dismissible.
  final VoidCallback? onDismiss;
  final VoidCallback? onSnooze;
  final VoidCallback? onRemove;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final urgency = deadline.urgency(now);
    final accent = DeadlineTone.accent(urgency);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(lead ? T.s24 : 14),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.all(
          color: lead ? accent : T.pencilGray,
          width: lead ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(lead ? T.rCard : T.rInput),
        boxShadow: lead ? T.floatShadow : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: lead ? 40 : 28,
                height: lead ? 40 : 28,
                decoration: BoxDecoration(
                  color: DeadlineTone.fill(urgency),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  DeadlineTone.icon(urgency),
                  size: lead ? 20 : 15,
                  color: accent,
                ),
              ),
              const SizedBox(width: T.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deadline.timing(now),
                      style: (lead ? AppTheme.label : AppTheme.caption)
                          .copyWith(color: accent, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      deadline.title,
                      style: lead
                          ? AppTheme.headingSm
                          : AppTheme.bodySm.copyWith(
                              color: T.ink,
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: T.s8), trailing!],
              if (deadline.dueDate != null)
                Padding(
                  padding: const EdgeInsets.only(left: T.s8),
                  child: Text(
                    deadline.dateLabel,
                    style: AppTheme.caption.copyWith(
                      color: T.graphite,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),

          if (lead) ...[
            const SizedBox(height: T.s16),
            Text(deadline.description, style: AppTheme.body),
            if (deadline.consequence.isNotEmpty) ...[
              const SizedBox(height: T.s16),
              _Line(
                icon: Icons.info_outline,
                label: 'If this slips',
                text: deadline.consequence,
              ),
            ],
            if (deadline.nextAction.isNotEmpty) ...[
              const SizedBox(height: T.s8),
              _Line(
                icon: Icons.arrow_forward,
                label: 'Do this next',
                text: deadline.nextAction,
                accent: accent,
              ),
            ],
          ] else ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 44),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (deadline.nextAction.isNotEmpty)
                    _Line(
                      icon: Icons.arrow_forward,
                      label: 'Next',
                      text: deadline.nextAction,
                      accent: accent,
                      dense: true,
                    ),
                  _Details(deadline: deadline),
                ],
              ),
            ),
          ],

          if (onDismiss != null || onSnooze != null || onRemove != null) ...[
            const SizedBox(height: T.s8),
            Padding(
              padding: EdgeInsets.only(left: lead ? 0 : 44),
              child: Wrap(
                spacing: T.s16,
                children: [
                  if (onSnooze != null)
                    _QuietAction(
                      label: 'Remind me later',
                      icon: Icons.snooze,
                      onPressed: onSnooze!,
                    ),
                  if (onDismiss != null)
                    _QuietAction(
                      label: 'Hide this',
                      icon: Icons.visibility_off_outlined,
                      onPressed: onDismiss!,
                    ),
                  if (onRemove != null)
                    _QuietAction(
                      label: 'Delete',
                      icon: Icons.delete_outline,
                      onPressed: onRemove!,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The folded-away half of a non-lead card. Everything is still reachable — it
/// is just not all shouting at once.
class _Details extends StatelessWidget {
  const _Details({required this.deadline});

  final Deadline deadline;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: T.s8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text('Why this is here', style: AppTheme.caption),
        children: [
          Text(deadline.description, style: AppTheme.bodySm),
          if (deadline.consequence.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            _Line(
              icon: Icons.info_outline,
              label: 'If this slips',
              text: deadline.consequence,
              dense: true,
            ),
          ],
          const SizedBox(height: T.s8),
          Text(deadline.source.label, style: AppTheme.caption),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.label,
    required this.text,
    this.accent,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final String text;
  final Color? accent;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? T.graphite;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: dense ? 13 : 15, color: color),
          ),
          const SizedBox(width: T.s8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: (dense ? AppTheme.caption : AppTheme.bodySm).copyWith(
                  color: T.graphite,
                ),
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: text),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A text-weight control. Dismissing something should never look like the most
/// important button on the card.
class _QuietAction extends StatelessWidget {
  const _QuietAction({
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
            Icon(icon, size: 13, color: T.pencilGray),
            const SizedBox(width: 5),
            Text(label, style: AppTheme.caption),
          ],
        ),
      ),
    );
  }
}

/// What the panel says when there is genuinely nothing to show. Honest about
/// why, and offers the one thing that would change it.
class DeadlineEmptyState extends StatelessWidget {
  const DeadlineEmptyState({
    super.key,
    required this.onSetUp,
    this.onAdd,
    this.hasSituation = false,
  });

  final VoidCallback onSetUp;
  final VoidCallback? onAdd;

  /// True when onboarding already has a status but no date — the message then
  /// asks for the missing half rather than starting from scratch.
  final bool hasSituation;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: T.pastelSky,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.event_note_outlined,
                size: 17,
                color: T.signalBlue,
              ),
            ),
            const SizedBox(width: T.s16),
            Expanded(
              child: Text(
                hasSituation
                    ? 'Tell me when your status expires and I\'ll track it from '
                          'there.'
                    : 'Nothing to track yet — and I would rather show you '
                          'nothing than make something up.',
                style: AppTheme.bodySm.copyWith(color: T.ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        Padding(
          padding: const EdgeInsets.only(left: 48),
          child: Text(
            'Give me the month your current status runs out and I can work '
            'backwards from it: when to start preparing, which windows open '
            'when, and what to check on your I-94.',
            style: AppTheme.bodySm,
          ),
        ),
        const SizedBox(height: T.s16),
        Padding(
          padding: const EdgeInsets.only(left: 48),
          child: Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              _EmptyAction(
                label: hasSituation
                    ? 'Add my expiry date'
                    : 'Tell me my situation',
                primary: true,
                onPressed: onSetUp,
              ),
              if (onAdd != null)
                _EmptyAction(label: 'Add a date myself', onPressed: onAdd!),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyAction extends StatelessWidget {
  const _EmptyAction({
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(T.rPill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: primary ? T.signalBlue : Colors.transparent,
          border: Border.all(color: primary ? T.signalBlue : T.pencilGray),
          borderRadius: BorderRadius.circular(T.rPill),
        ),
        child: Text(
          label,
          style: AppTheme.label.copyWith(
            color: primary ? T.paper : T.carbon,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
