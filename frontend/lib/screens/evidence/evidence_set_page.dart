import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/evidence.dart';
import '../../services/evidence_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/evidence_disclaimer.dart';
import '../../widgets/evidence_readiness_card.dart';
import '../../widgets/evidence_strength_picker.dart';
import '../../widgets/pill_button.dart';
import 'evidence_scaffold.dart';

/// `/evidence/:setId` — one visa category.
///
/// Readiness at the top in plain words, then the list of criteria, one row
/// each, each opening its own screen. Nothing on this page is a wall of legal
/// text; the long explanations live one level down where they are asked for.
class EvidenceSetPage extends StatelessWidget {
  const EvidenceSetPage({super.key, required this.setId});

  final String setId;

  @override
  Widget build(BuildContext context) {
    return EvidenceLoader(
      builder: (context, service) {
        final set = service.catalog!.set(setId);
        if (set == null) {
          return EvidenceScaffold(
            children: [
              Text('No such category: $setId', style: AppTheme.headingSm),
              const SizedBox(height: T.s16),
              PillButton(
                label: 'Back to the overview',
                onPressed: () => context.go('/evidence'),
              ),
            ],
          );
        }

        final readiness = service.readinessFor(set);
        final actions = service.nextActions(set);

        return EvidenceScaffold(
          children: [
            _BackLink(onTap: () => context.go('/evidence')),
            const SizedBox(height: T.s24),
            Text(set.visaCode, style: AppTheme.heading(context)),
            const SizedBox(height: T.s8),
            Text(set.title, style: AppTheme.subheading),
            const SizedBox(height: T.s24),
            Text(set.summary, style: AppTheme.body),
            if (set.sponsorship.isNotEmpty) ...[
              const SizedBox(height: T.s16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.badge_outlined,
                    size: 16,
                    color: T.pencilGray,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(set.sponsorship, style: AppTheme.bodySm),
                  ),
                ],
              ),
            ],

            const SizedBox(height: T.s32),
            _ReadinessPanel(readiness: readiness),

            if (readiness.hasStarted) ...[
              const SizedBox(height: T.s24),
              _ProfileTracker(set: set, service: service),
            ],

            if (set.structureExplainer != null) ...[
              const SizedBox(height: T.s24),
              _NoteBlock(
                icon: Icons.account_tree_outlined,
                title: 'How this one is shaped',
                body: set.structureExplainer!,
                color: T.pastelPeach,
              ),
            ],

            if (set.twoStep != null) ...[
              const SizedBox(height: T.s24),
              _TwoStepPanel(twoStep: set.twoStep!),
            ],

            if (set.uncertaintyNote != null) ...[
              const SizedBox(height: T.s24),
              EvidenceUncertaintyNote(text: set.uncertaintyNote!),
            ],

            if (actions.isNotEmpty) ...[
              const SizedBox(height: T.s32),
              const EvidenceSectionTitle(
                'Cheapest next moves',
                icon: Icons.trending_up,
              ),
              const SizedBox(height: T.s16),
              for (final action in actions) ...[
                EvidenceNextActionCard(
                  action: action,
                  onOpen: () =>
                      context.go('/evidence/$setId/${action.item.id}'),
                ),
                const SizedBox(height: T.s16),
              ],
            ],

            if (set.gates.isNotEmpty) ...[
              const SizedBox(height: T.s32),
              const EvidenceSectionTitle(
                'Requirements — these come first',
                icon: Icons.flag_outlined,
              ),
              const SizedBox(height: T.s16),
              _ItemList(items: set.gates, setId: setId, service: service),
            ],

            if (set.conditions.isNotEmpty) ...[
              const SizedBox(height: T.s32),
              const EvidenceSectionTitle(
                'Conditions — generally all must hold',
                icon: Icons.checklist_outlined,
              ),
              const SizedBox(height: T.s16),
              _ItemList(items: set.conditions, setId: setId, service: service),
            ],

            if (set.criteria.isNotEmpty) ...[
              const SizedBox(height: T.s32),
              EvidenceSectionTitle(
                set.threshold == null
                    ? 'The criteria'
                    : 'The ${set.criteria.length} criteria — typically at '
                          'least ${set.threshold} needed',
                icon: Icons.checklist_rtl_outlined,
              ),
              const SizedBox(height: T.s8),
              Text(set.howItIsJudged, style: AppTheme.bodySm),
              const SizedBox(height: T.s16),
              _ItemList(items: set.criteria, setId: setId, service: service),
            ],

            if (set.oneTimeAchievement != null) ...[
              const SizedBox(height: T.s32),
              _OneTimePanel(award: set.oneTimeAchievement!),
            ],

            const SizedBox(height: T.s32),
            EvidenceDisclaimer(
              text: service.catalog!.meta.disclaimer,
              compact: true,
            ),
            const SizedBox(height: T.s16),
            const EvidencePrivacyNote(),
          ],
        );
      },
    );
  }
}

class _ReadinessPanel extends StatelessWidget {
  const _ReadinessPanel({required this.readiness});

  final EvidenceReadiness readiness;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.cardPadding),
      decoration: BoxDecoration(
        color: T.pastelSky.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Where you are', style: AppTheme.badge),
          const SizedBox(height: T.s8),
          Text(
            readiness.hasStarted
                ? readiness.headline
                : 'Nothing marked yet. That is the normal starting point.',
            style: AppTheme.headingSm.copyWith(fontSize: 19),
          ),
          const SizedBox(height: T.s16),
          EvidenceProgressBar(value: readiness.progress),
          const SizedBox(height: T.s16),
          Text(readiness.detail, style: AppTheme.bodySm),
          if (readiness.criteriaMoving > 0) ...[
            const SizedBox(height: T.s8),
            Text(
              '${readiness.criteriaMoving} more marked as in progress — '
              'usually the cheapest to finish.',
              style: AppTheme.bodySm,
            ),
          ],
          if (!readiness.hasStarted && readiness.encouragement.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            Text(readiness.encouragement, style: AppTheme.bodySm),
          ],
        ],
      ),
    );
  }
}

class _TwoStepPanel extends StatelessWidget {
  const _TwoStepPanel({required this.twoStep});

  final TwoStepExplainer twoStep;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.cardPadding),
      decoration: BoxDecoration(
        color: T.pastelLavender.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('The part people miss', style: AppTheme.badge),
          const SizedBox(height: T.s8),
          Text(
            'Judged in two separate steps',
            style: AppTheme.headingSm.copyWith(fontSize: 19),
          ),
          const SizedBox(height: T.s24),
          _Step(
            number: '1',
            name: twoStep.stepOneName,
            body: twoStep.stepOneMeans,
            note: twoStep.stepOneNote,
          ),
          const SizedBox(height: T.s24),
          _Step(
            number: '2',
            name: twoStep.stepTwoName,
            body: twoStep.stepTwoMeans,
            note: twoStep.stepTwoNote,
          ),
          if (twoStep.whyItMatters.isNotEmpty) ...[
            const SizedBox(height: T.s24),
            Text(
              twoStep.whyItMatters,
              style: AppTheme.body.copyWith(color: T.carbon),
            ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.name,
    required this.body,
    this.note,
  });

  final String number;
  final String name;
  final String body;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: const BoxDecoration(color: T.ink, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(
            number,
            style: AppTheme.badge.copyWith(color: T.paper, fontSize: 12),
          ),
        ),
        const SizedBox(width: T.s16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: AppTheme.label.copyWith(
                  color: T.ink,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              Text(body, style: AppTheme.body),
              if (note != null) ...[
                const SizedBox(height: T.s8),
                Text(note!, style: AppTheme.bodySm.copyWith(color: T.carbon)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _OneTimePanel extends StatelessWidget {
  const _OneTimePanel({required this.award});

  final OneTimeAchievement award;

  @override
  Widget build(BuildContext context) {
    return _NoteBlock(
      icon: Icons.emoji_events_outlined,
      title: award.name,
      body: award.note == null
          ? award.means
          : '${award.means}\n\n${award.note}',
      color: T.pastelYellow,
    );
  }
}

class _NoteBlock extends StatelessWidget {
  const _NoteBlock({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.cardPadding),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: T.ink),
              const SizedBox(width: T.s8),
              Expanded(
                child: Text(
                  title,
                  style: AppTheme.label.copyWith(
                    color: T.ink,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: T.s8),
          Text(body, style: AppTheme.body),
        ],
      ),
    );
  }
}

/// The criteria list: one row per item, strength visible, detail one tap away.
class _ItemList extends StatelessWidget {
  const _ItemList({
    required this.items,
    required this.setId,
    required this.service,
  });

  final List<EvidenceItem> items;
  final String setId;
  final EvidenceService service;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: T.s8),
            child: _ItemRow(
              item: item,
              strength: service.strengthFor(item.id),
              onOpen: () => context.go('/evidence/$setId/${item.id}'),
            ),
          ),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.strength,
    required this.onOpen,
  });

  final EvidenceItem item;
  final EvidenceStrength strength;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(T.s16),
          decoration: BoxDecoration(
            color: T.paper,
            borderRadius: BorderRadius.circular(T.rInput),
            border: Border.fromBorderSide(T.hairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: EvidenceStrengthDot(strength: strength),
              ),
              const SizedBox(width: T.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: AppTheme.label.copyWith(color: T.ink),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      strength == EvidenceStrength.notStarted
                          ? item.timeToBuild
                          : strength.label,
                      style: AppTheme.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: T.s8),
              const Icon(Icons.chevron_right, size: 18, color: T.pencilGray),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileTracker extends StatelessWidget {
  const _ProfileTracker({required this.set, required this.service});

  final EvidenceSet set;
  final EvidenceService service;

  @override
  Widget build(BuildContext context) {
    final criteria = set.criteria;
    if (criteria.isEmpty) return const SizedBox.shrink();

    final met = criteria
        .where((c) =>
            service.strengthFor(c.id) == EvidenceStrength.strong ||
            service.strengthFor(c.id) == EvidenceStrength.haveEvidence)
        .length;
    final inProgress =
        criteria.where((c) => service.strengthFor(c.id).isMoving).length;
    final total = criteria.length;
    final remaining = total - met - inProgress;

    return Container(
      padding: const EdgeInsets.all(T.cardPadding),
      decoration: BoxDecoration(
        color: T.pastelMint.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your progress snapshot', style: AppTheme.badge),
          const SizedBox(height: T.s16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _TrackerStat(
                label: 'Criteria met',
                value: met.toString(),
                color: T.signalBlue,
              ),
              _TrackerStat(
                label: 'In progress',
                value: inProgress.toString(),
                color: T.pastelMint,
              ),
              _TrackerStat(
                label: 'To-do',
                value: remaining.toString(),
                color: T.pastelPink,
              ),
            ],
          ),
          const SizedBox(height: T.s16),
          Text(
            set.threshold == null
                ? 'Keep building your profile.'
                : 'You need at least ${set.threshold} criteria. '
                    '$met of $total done.',
            style: AppTheme.bodySm,
          ),
        ],
      ),
    );
  }
}

class _TrackerStat extends StatelessWidget {
  const _TrackerStat({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(T.rInput),
          ),
          alignment: Alignment.center,
          child: Text(
            value,
            style: AppTheme.heading(context).copyWith(fontSize: 20, color: color),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: AppTheme.caption),
      ],
    );
  }
}

class _BackLink extends StatelessWidget {
  const _BackLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.arrow_back, size: 15, color: T.graphite),
            const SizedBox(width: 8),
            Text('All categories', style: AppTheme.label),
          ],
        ),
      ),
    );
  }
}
