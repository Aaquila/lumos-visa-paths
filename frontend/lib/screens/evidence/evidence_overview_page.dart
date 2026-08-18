import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/evidence.dart';
import '../../services/auth_service.dart';
import '../../services/case_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/evidence_disclaimer.dart';
import '../../widgets/evidence_readiness_card.dart';
import 'evidence_scaffold.dart';

/// `/evidence` — the profile-building overview.
///
/// One card per category, each stating readiness in words rather than as a
/// score, plus the one or two highest-leverage things to do next. Everything
/// deeper lives one tap away, so this page stays readable in a minute.
class EvidenceOverviewPage extends StatelessWidget {
  const EvidenceOverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return EvidenceLoader(
      builder: (context, service) {
        final catalog = service.catalog!;
        final profile = CaseService.instance.profile;

        // Filter evidence sets by user's selected visa type
        final displaySets = profile?.currentNodeId != null
            ? catalog.sets
                .where((set) => set.pathwayNodeId == profile!.currentNodeId)
                .toList()
            : catalog.sets;

        final readiness = service.allReadiness();
        final actions = service.topActions(limit: 2);
        final started = readiness.any((r) => r.hasStarted);
        final name = AuthService.instance.session?.preferredName;
        final compact = Breaks.isMobile(context);

        // Get visa code for personalized heading
        final visaCode = displaySets.isNotEmpty
            ? displaySets.first.visaCode
            : 'O-1/EB-1';

        return EvidenceScaffold(
          maxWidth: 880,
          children: [
            Text(
              name == null
                  ? 'Building your $visaCode profile'
                  : '$name, here is your $visaCode profile',
              style: AppTheme.heading(context),
            ),
            const SizedBox(height: T.s16),
            Text(
              'These petitions are won on evidence gathered over years, not a '
              'form filled in over a weekend. This page maps what that '
              'evidence is.',
              style: AppTheme.subheading,
            ),
            const SizedBox(height: T.s8),
            Text(
              started
                  ? 'Pick up where you left off.'
                  : 'Nothing is recorded yet — that is the normal place to '
                        'start. Almost nobody meets these criteria on the '
                        'first read.',
              style: AppTheme.body,
            ),
            const SizedBox(height: T.s32),
            EvidenceDisclaimer(text: catalog.meta.disclaimer),
            const SizedBox(height: T.s16),
            EvidencePrivacyNote(text: catalog.meta.privacyNote),

            if (actions.isNotEmpty) ...[
              const SizedBox(height: T.s48),
              const EvidenceSectionTitle(
                'Where to spend your next hour',
                icon: Icons.trending_up,
              ),
              const SizedBox(height: T.s16),
              for (final action in actions) ...[
                EvidenceNextActionCard(
                  action: action,
                  showSetCode:
                      catalog.set(action.setId)?.visaCode ?? action.setId,
                  onOpen: () =>
                      context.go('/evidence/${action.setId}/${action.item.id}'),
                ),
                const SizedBox(height: T.s16),
              ],
            ],

            const SizedBox(height: T.s32),
            const EvidenceSectionTitle(
              'The five categories',
              icon: Icons.list_alt_outlined,
            ),
            const SizedBox(height: T.s8),
            Text(
              'They are scored differently. Three count criteria; EB-1B puts '
              'requirements first; EB-1C counts nothing.',
              style: AppTheme.bodySm,
            ),
            const SizedBox(height: T.s24),
            if (displaySets.isNotEmpty)
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = compact ? 1 : 2;
                  const gap = T.s16;
                  final width =
                      (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final set in displaySets)
                        SizedBox(
                          width: width,
                          child: EvidenceReadinessCard(
                            set: set,
                            readiness: service.readinessFor(set),
                            onOpen: () =>
                                context.go('/evidence/${set.id}'),
                          ),
                        ),
                    ],
                  );
                },
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: T.s24),
                child: Text(
                  'Complete your intake to see your personalized visa category profile.',
                  style: AppTheme.body,
                ),
              ),

            const SizedBox(height: T.s48),
            _AsOfNote(meta: catalog.meta),
          ],
        );
      },
    );
  }
}

class _AsOfNote extends StatelessWidget {
  const _AsOfNote({required this.meta});

  final EvidenceMeta meta;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(T.rInput),
        border: Border.fromBorderSide(T.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reference last checked ${meta.asOf}',
            style: AppTheme.label.copyWith(color: T.ink),
          ),
          const SizedBox(height: 6),
          Text(meta.warning, style: AppTheme.caption),
          if (meta.selfAssessmentNote.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            Text(meta.selfAssessmentNote, style: AppTheme.caption),
          ],
        ],
      ),
    );
  }
}
