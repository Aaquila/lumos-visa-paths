import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/deadline.dart';
import '../../models/pathway_graph.dart';
import '../../services/auth_service.dart';
import '../../services/case_service.dart';
import '../../services/deadline_service.dart';
import '../../services/pathway_repository.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/add_deadline_sheet.dart';
import '../../widgets/badges.dart';
import '../../widgets/deadline_card.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/site_footer.dart';
import '../../widgets/site_nav.dart';

/// Every date, in one place — the "show all" the dashboard links to.
///
/// Still paced rather than dumped: the nearest item is a full card, the next
/// four are compact, and anything past that sits behind one tap. Hidden and
/// snoozed items get their own section at the bottom, because "I dismissed
/// something and now I cannot find it" is its own small panic.
///
/// Route to register in `app/router.dart` (not owned by this file):
/// `GoRoute(path: '/deadlines', builder: (_, __) => const DeadlinesPage())`.
class DeadlinesPage extends StatefulWidget {
  const DeadlinesPage({super.key, this.now});

  /// Injected only by tests.
  final DateTime? now;

  @override
  State<DeadlinesPage> createState() => _DeadlinesPageState();
}

class _DeadlinesPageState extends State<DeadlinesPage> {
  late final Future<PathwayGraph> _graph = PathwayRepository.instance.load();

  /// Start folded. Five is about the number of open loops a person can hold.
  static const _initialCap = 5;
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    CaseService.instance.load();
    DeadlineService.instance.load();
  }

  Future<void> _add(DateTime now) async {
    final created = await showAddDeadlineSheet(context, now: now);
    if (created != null) await DeadlineService.instance.add(created);
  }

  Future<void> _snooze(Deadline deadline, DateTime now) async {
    await DeadlineService.instance.snooze(
      deadline.id,
      DateTime(now.year, now.month, now.day + 14),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Put away for two weeks — it will come back on its own.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => DeadlineService.instance.restore(deadline.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);
    final now = widget.now ?? DateTime.now();

    return Scaffold(
      backgroundColor: T.paper,
      body: AnimatedBuilder(
        animation: Listenable.merge([
          AuthService.instance,
          CaseService.instance,
          DeadlineService.instance,
        ]),
        builder: (context, _) {
          return FutureBuilder<PathwayGraph>(
            future: _graph,
            builder: (context, snapshot) {
              final service = DeadlineService.instance;
              final situation = AuthService.instance.onboarding.situation;
              final profile = CaseService.instance.profile;
              final graph = snapshot.data;

              final items = service.visible(
                situation: situation,
                profile: profile,
                graph: graph,
                now: now,
              );
              final hidden = service.hidden(
                situation: situation,
                profile: profile,
                graph: graph,
                now: now,
              );
              final shown = _showAll ? items : items.take(_initialCap).toList();
              final rest = items.length - shown.length;

              return Column(
                children: [
                  const SiteNav(transparent: false),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: mobile ? T.s24 : T.s32,
                              vertical: T.s48,
                            ),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 860,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const StepBadge(
                                      step: 'Your dates',
                                      descriptor: 'kept on this device',
                                    ),
                                    const SizedBox(height: T.s16),
                                    Text(
                                      'What is coming up',
                                      style: AppTheme.headingLg(context),
                                    ),
                                    const SizedBox(height: T.s8),
                                    Text(
                                      'Worked out from your status and the '
                                      'pathway you confirmed. Nothing here '
                                      'leaves your browser.',
                                      style: AppTheme.body,
                                    ),
                                    const SizedBox(height: T.s24),

                                    if (items.isEmpty)
                                      DeadlineEmptyState(
                                        hasSituation:
                                            situation?.hasStatus ?? false,
                                        onSetUp: () =>
                                            context.go('/onboarding/situation'),
                                        onAdd: () => _add(now),
                                      )
                                    else ...[
                                      for (var i = 0; i < shown.length; i++)
                                        Padding(
                                          padding: EdgeInsets.only(
                                            bottom: i == 0 ? T.s16 : T.s8,
                                          ),
                                          child: DeadlineCard(
                                            deadline: shown[i],
                                            now: now,
                                            lead: i == 0,
                                            onSnooze: () =>
                                                _snooze(shown[i], now),
                                            onDismiss:
                                                shown[i].dismissible &&
                                                    shown[i].source.isDerived
                                                ? () => service.dismiss(
                                                    shown[i].id,
                                                  )
                                                : null,
                                            onRemove:
                                                shown[i].source ==
                                                    DeadlineSource.userAdded
                                                ? () => service.remove(
                                                    shown[i].id,
                                                  )
                                                : null,
                                          ),
                                        ),
                                      if (rest > 0)
                                        PillButton(
                                          label: 'Show all $rest more',
                                          icon: Icons.expand_more,
                                          onPressed: () =>
                                              setState(() => _showAll = true),
                                        ),
                                    ],

                                    const SizedBox(height: T.s24),
                                    Wrap(
                                      spacing: T.s8,
                                      runSpacing: T.s8,
                                      children: [
                                        PillButton(
                                          label: 'Add a date',
                                          variant: PillVariant.signal,
                                          icon: Icons.add,
                                          onPressed: () => _add(now),
                                        ),
                                        PillButton(
                                          label: 'Back to my dashboard',
                                          icon: Icons.arrow_back,
                                          onPressed: () =>
                                              context.go('/dashboard'),
                                        ),
                                      ],
                                    ),

                                    if (hidden.isNotEmpty) ...[
                                      const SizedBox(height: T.s40),
                                      Text(
                                        'Put away',
                                        style: AppTheme.headingSm,
                                      ),
                                      const SizedBox(height: T.s8),
                                      Text(
                                        "Hidden or snoozed. Nothing's "
                                        'deleted — bring it back anytime.',
                                        style: AppTheme.bodySm,
                                      ),
                                      const SizedBox(height: T.s16),
                                      for (final d in hidden)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: T.s8,
                                          ),
                                          child: _HiddenRow(
                                            deadline: d,
                                            onRestore: () =>
                                                service.restore(d.id),
                                          ),
                                        ),
                                    ],

                                    const SizedBox(height: T.s32),
                                    Text(
                                      Deadline.disclaimer,
                                      style: AppTheme.caption,
                                    ),
                                    const SizedBox(height: T.s16),
                                    const LegalDisclaimer(compact: true),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SiteFooter(),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _HiddenRow extends StatelessWidget {
  const _HiddenRow({required this.deadline, required this.onRestore});

  final Deadline deadline;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rInput),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              deadline.title,
              style: AppTheme.bodySm.copyWith(color: T.graphite),
            ),
          ),
          TextButton(onPressed: onRestore, child: const Text('Bring it back')),
        ],
      ),
    );
  }
}
