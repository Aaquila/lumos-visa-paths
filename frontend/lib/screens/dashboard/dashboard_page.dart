import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/case_profile.dart';
import '../../models/evidence.dart';
import '../../models/news_item.dart';
import '../../models/pathway_graph.dart';
import '../../services/auth_service.dart';
import '../../services/case_service.dart';
import '../../services/deadline_service.dart';
import '../../services/evidence_service.dart';
import '../../services/news_service.dart';
import '../../services/pathway_repository.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/deadline_panel.dart';
import '../../widgets/evidence_readiness_card.dart';
import '../../widgets/news_notification_bar.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/site_footer.dart';
import '../../widgets/site_nav.dart';
import '../../widgets/voice_assistant_panel.dart';
import '../evidence/evidence_scaffold.dart' show EvidenceLoader;
import '../landing/landing_mockups.dart';

/// The personal page "Get started" leads to once a session exists.
///
/// Everything here hangs off the case the person confirmed at `/intake`: the
/// status stamp, the alerts filter, the route strip. Before that exists the
/// page says so and offers the one action that matters, rather than showing a
/// sample case that looks like theirs.
///
/// The deadline block is the exception to that: it is derived locally by
/// [DeadlineService] from the onboarding answers and the pathway graph, and
/// stays on the device. It appears even before intake has run, because the
/// dates hang off what onboarding was told, not off a confirmed pathway.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  late final Future<PathwayGraph> _graph = PathwayRepository.instance.load();
  int _unreadNewsCount = 0;
  bool _newsBarDismissed = false;

  @override
  void initState() {
    super.initState();
    CaseService.instance.load();
    DeadlineService.instance.load();
    _loadUnreadCount();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Load unread news count when app becomes visible
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadUnreadCount();
    }
  }

  Future<void> _loadUnreadCount() async {
    try {
      final count = await NewsService.instance.getUnreadCount();
      if (mounted) {
        setState(() {
          _unreadNewsCount = count;
          // Reset dismissal when count changes
          if (count > 0) {
            _newsBarDismissed = false;
          }
        });
      }
    } catch (_) {
      // Silently fail on network errors
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    return Scaffold(
      backgroundColor: T.paper,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showVoiceAssistantSheet(context),
        icon: const Icon(Icons.mic_none),
        label: const Text('Ask Lumos'),
        backgroundColor: T.signalBlue,
        foregroundColor: T.paper,
      ),
      body: AnimatedBuilder(
        // Sign-in state and the case can both change from elsewhere.
        animation: Listenable.merge([
          AuthService.instance,
          CaseService.instance,
        ]),
        builder: (context, _) {
          final profile = CaseService.instance.profile;
          final currentNodeId = profile?.currentNodeId;

          return Column(
            children: [
              // Show notification bar if there are unread articles and not dismissed
              if (_unreadNewsCount > 0 && !_newsBarDismissed)
                NewsNotificationBar(
                  unreadCount: _unreadNewsCount,
                  onViewPressed: () {
                    context.go('/news');
                  },
                  onDismissed: () {
                    setState(() => _newsBarDismissed = true);
                  },
                ),
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
                              maxWidth: T.pageMaxWidth,
                            ),
                            child: FutureBuilder<PathwayGraph>(
                              future: _graph,
                              builder: (context, snapshot) {
                                final graph = snapshot.data;

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(child: const _Greeting()),
                                        if (!mobile)
                                          PillButton(
                                            label: 'Sign out',
                                            icon: Icons.logout,
                                            onPressed: () {
                                              // The case is per-account and
                                              // stays on disk; drop it from
                                              // memory so the next sign-in
                                              // starts from its own.
                                              CaseService.instance.forget();
                                              AuthService.instance.signOut();
                                              context.go('/');
                                            },
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: T.s40),

                                    if (profile == null) ...[
                                      const _IntakePrompt(),
                                      const SizedBox(height: T.s24),
                                      // Dates come from onboarding, not from
                                      // intake — so somebody who has told us
                                      // when their status ends gets tracking
                                      // straight away, before any of the rest
                                      // of this page can fill in.
                                      _Panel(
                                        mobile: true,
                                        title: 'Next deadlines',
                                        child: DeadlinePanel(
                                          situation: AuthService
                                              .instance
                                              .onboarding
                                              .situation,
                                          profile: null,
                                          graph: graph,
                                        ),
                                      ),
                                    ] else ...[
                                      _StatusStamp(
                                        profile: profile,
                                        node: graph?.node(
                                          profile.currentNodeId ?? '',
                                        ),
                                        goal: graph?.node(
                                          profile.goalNodeId ?? '',
                                        ),
                                        mobile: mobile,
                                      ),
                                      const SizedBox(height: T.s24),

                                      Flex(
                                        direction: mobile
                                            ? Axis.vertical
                                            : Axis.horizontal,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _Panel(
                                            mobile: mobile,
                                            flex: 3,
                                            title: 'Next deadlines',
                                            child: DeadlinePanel(
                                              situation: AuthService
                                                  .instance
                                                  .onboarding
                                                  .situation,
                                              profile: profile,
                                              graph: graph,
                                            ),
                                          ),
                                          const SizedBox(
                                            width: T.s24,
                                            height: T.s24,
                                          ),
                                          _Panel(
                                            mobile: mobile,
                                            flex: 2,
                                            title: 'News alerts',
                                            action: 'GET /api/news/alerts',
                                            onTitleTap: () => context.go(
                                              currentNodeId == null
                                                  ? '/news'
                                                  : '/news?node=$currentNodeId',
                                            ),
                                            child: _AlertList(
                                              nodeId: currentNodeId,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: T.s24),

                                      // Mini route strip — the map in miniature.
                                      // Real when we know both ends; the
                                      // illustrative default otherwise.
                                      _RoutePanel(
                                        mobile: mobile,
                                        graph: graph,
                                        currentNodeId: currentNodeId,
                                        goalNodeId: profile.goalNodeId,
                                      ),

                                      if (EvidenceService.isTalentTrack(
                                        profile,
                                      )) ...[
                                        const SizedBox(height: T.s24),
                                        _TalentEvidencePanel(
                                          profile: profile,
                                        ),
                                      ],
                                    ],

                                    const SizedBox(height: T.s24),
                                  ],
                                );
                              },
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
      ),
    );
  }
}

/// The page greeting.
///
/// The name comes from the onboarding picker (one of three, chosen on a
/// screen). There is no name input anywhere in the app — if the user has not
/// picked yet, the greeting simply carries no name.
class _Greeting extends StatelessWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context) {
    final name = AuthService.instance.session?.chosenName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StepBadge(step: 'Your pathway', descriptor: 'personal map'),
        const SizedBox(height: T.s16),
        Text(
          name == null ? 'Welcome back.' : 'Welcome back, $name.',
          style: AppTheme.headingLg(context),
        ),
      ],
    );
  }
}

/// Shown until intake has run: one action, and an honest reason for it.
class _IntakePrompt extends StatelessWidget {
  const _IntakePrompt();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s32),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.all(color: T.signalBlue, width: 2),
        borderRadius: BorderRadius.circular(T.rFeatureCard),
        boxShadow: T.floatShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PastelIconBadge(
            icon: Icons.explore_outlined,
            fill: T.pastelSky,
            size: 40,
          ),
          const SizedBox(height: T.s16),
          Text('Start with where you are', style: AppTheme.headingSm),
          const SizedBox(height: T.s8),
          Text(
            'Deadlines, policy updates, the route on the map — all of it '
            'hangs off two facts: where you are today, and where you want '
            'to end up. Tell us those and the page fills in. Until then it '
            'would only be guessing, so it does not.',
            style: AppTheme.body,
          ),
          const SizedBox(height: T.s24),
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              PillButton(
                label: 'Set up my pathway',
                variant: PillVariant.signal,
                trailingIcon: Icons.arrow_forward,
                onPressed: () => context.go('/intake'),
              ),
              PillButton(
                label: 'Answer a few questions',
                icon: Icons.checklist_rtl,
                onPressed: () => context.go('/intake?mode=questions'),
              ),
              PillButton(
                label: 'Browse the map first',
                icon: Icons.map_outlined,
                onPressed: () => context.go('/visa-pathways'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "You are here", and — once someone has said so — where they are heading.
class _StatusStamp extends StatelessWidget {
  const _StatusStamp({
    required this.profile,
    required this.node,
    required this.goal,
    required this.mobile,
  });

  final CaseProfile profile;
  final PathwayNode? node;
  final PathwayNode? goal;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s32),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.all(color: T.signalBlue, width: 2),
        borderRadius: BorderRadius.circular(T.rFeatureCard),
        boxShadow: T.floatShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flex(
            direction: mobile ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: mobile ? 0 : 1,
                child: _Half(
                  icon: Icons.place,
                  fill: T.pastelSky,
                  accent: T.signalBlue,
                  label: 'You are here',
                  name: node?.name ?? 'Status not resolved yet',
                  body:
                      node?.description ??
                      'Intake could not place you. Re-run it, or answer the '
                          'questions, to fix that.',
                ),
              ),
              SizedBox(width: mobile ? 0 : T.s32, height: mobile ? T.s24 : 0),
              Expanded(
                flex: mobile ? 0 : 1,
                child: _Half(
                  icon: Icons.flag_outlined,
                  fill: T.pastelLavender,
                  accent: T.voltageViolet,
                  label: 'You want to be here',
                  name: goal?.name ?? 'No destination set',
                  body:
                      goal?.description ??
                      'No goal named yet, so the map keeps every route open.',
                ),
              ),
            ],
          ),
          const SizedBox(height: T.s24),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${profile.source.label}'
                  '${profile.degraded ? ' · service was unavailable' : ''}',
                  style: AppTheme.caption,
                ),
              ),
              PillButton(
                label: 'Redo intake',
                icon: Icons.refresh,
                onPressed: () => context.go('/intake'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Half extends StatelessWidget {
  const _Half({
    required this.icon,
    required this.fill,
    required this.accent,
    required this.label,
    required this.name,
    required this.body,
  });

  final IconData icon;
  final Color fill;
  final Color accent;
  final String label;
  final String name;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PastelIconBadge(icon: icon, fill: fill, size: 40),
        const SizedBox(width: T.s16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: AppTheme.badge.copyWith(color: accent, letterSpacing: 1),
              ),
              const SizedBox(height: 6),
              Text(name, style: AppTheme.headingSm),
              const SizedBox(height: 6),
              Text(body, style: AppTheme.bodySm),
            ],
          ),
        ),
      ],
    );
  }
}

/// Live policy updates matched to the user's current status, from the scraper
/// backend. Falls back to an honest "not reachable" line rather than sample
/// data, so nobody mistakes a stub for a real alert.
class _AlertList extends StatefulWidget {
  const _AlertList({required this.nodeId});

  /// Null when intake did not resolve a status — the feed is then unfiltered,
  /// and says so.
  final String? nodeId;

  @override
  State<_AlertList> createState() => _AlertListState();
}

class _AlertListState extends State<_AlertList> {
  late Future<NewsFeed> _feed = _load();

  Future<NewsFeed> _load() =>
      NewsService.instance.alerts(nodeId: widget.nodeId, limit: 4);

  @override
  void didUpdateWidget(_AlertList old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) _feed = _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<NewsFeed>(
      future: _feed,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: T.s24),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final feed = snapshot.data ?? NewsFeed.empty;
        if (feed.offline) {
          return _note(
            Icons.cloud_off,
            'The updates service is not running, so alerts cannot be '
            'checked right now.',
          );
        }
        if (feed.items.isEmpty) {
          return _note(
            Icons.check_circle_outline,
            'Nothing new touching your status right now.',
          );
        }

        return Column(
          children: [
            if (widget.nodeId == null)
              Padding(
                padding: const EdgeInsets.only(bottom: T.s8),
                child: _note(
                  Icons.filter_alt_off_outlined,
                  'Showing every update, not just yours — set up your '
                  'pathway to filter it.',
                ),
              ),
            for (final item in feed.items.take(3))
              Container(
                margin: const EdgeInsets.only(bottom: T.s8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.fromBorderSide(T.hairline),
                  borderRadius: BorderRadius.circular(T.rInput),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.notifications_active_outlined,
                            size: 14,
                            color: T.signalBlue,
                          ),
                        ),
                        const SizedBox(width: T.s8),
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.bodySm.copyWith(
                              color: T.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(item.sourceName, style: AppTheme.caption),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: PillButton(
                label: 'All updates',
                icon: Icons.article_outlined,
                onPressed: () => context.go(
                  widget.nodeId == null
                      ? '/news'
                      : '/news?node=${widget.nodeId}',
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _note(IconData icon, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 14, color: T.pencilGray),
      const SizedBox(width: T.s8),
      Expanded(child: Text(text, style: AppTheme.bodySm)),
    ],
  );
}

class _RoutePanel extends StatelessWidget {
  const _RoutePanel({
    required this.mobile,
    required this.graph,
    required this.currentNodeId,
    required this.goalNodeId,
  });

  final bool mobile;
  final PathwayGraph? graph;
  final String? currentNodeId;
  final String? goalNodeId;

  @override
  Widget build(BuildContext context) {
    final computed =
        graph != null && currentNodeId != null && goalNodeId != null
        ? graph!.computeRoute(currentNodeId!, goalNodeId!)
        : null;
    final spine = computed ?? SpinePreview.defaultSpine;
    final branch = computed == null ? SpinePreview.defaultBranch : null;

    return _Panel(
      mobile: true,
      title: 'Your route',
      action: 'GET /api/pathways/personal',
      child: Column(
        children: [
          SizedBox(
            height: 240,
            child: graph == null
                ? const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : mobile
                // The spine needs width to read; let it scroll on narrow
                // screens.
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: 780,
                      height: 240,
                      child: SpinePreview(
                        graph: graph!,
                        youAreHere: currentNodeId,
                        spine: spine,
                        branchNodeId: branch,
                      ),
                    ),
                  )
                : SpinePreview(
                    graph: graph!,
                    youAreHere: currentNodeId,
                    spine: spine,
                    branchNodeId: branch,
                  ),
          ),
          const SizedBox(height: T.s16),
          Align(
            alignment: Alignment.centerLeft,
            child: PillButton(
              label: 'Open the full pathways map',
              variant: PillVariant.ink,
              trailingIcon: Icons.arrow_forward,
              onPressed: () => context.go(
                currentNodeId == null
                    ? '/visa-pathways'
                    : '/visa-pathways?node=$currentNodeId',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The O-1/EB-1 evidence tracker, in miniature, for anyone whose current
/// status or goal is on that talent track — otherwise it lives only behind
/// the "O-1 / EB-1" nav link.
class _TalentEvidencePanel extends StatelessWidget {
  const _TalentEvidencePanel({required this.profile});

  final CaseProfile profile;

  @override
  Widget build(BuildContext context) {
    return EvidenceLoader(
      builder: (context, service) {
        final catalog = service.catalog;
        if (catalog == null) return const SizedBox.shrink();

        // The resolved category (if any) leads; everything else follows in
        // catalog order.
        final sets = [...catalog.sets]
          ..sort((a, b) {
            bool matches(EvidenceSet s) =>
                s.pathwayNodeId == profile.currentNodeId ||
                s.pathwayNodeId == profile.goalNodeId;
            final aFirst = matches(a) ? 0 : 1;
            final bFirst = matches(b) ? 0 : 1;
            return aFirst.compareTo(bFirst);
          });
        final shown = sets.take(3);

        return Container(
          padding: const EdgeInsets.all(T.s24),
          decoration: BoxDecoration(
            color: T.paper,
            border: Border.fromBorderSide(T.hairline),
            borderRadius: BorderRadius.circular(T.rFeatureCard),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('O-1 / EB-1 evidence', style: AppTheme.headingSm),
              const SizedBox(height: T.s16),
              Wrap(
                spacing: T.s16,
                runSpacing: T.s16,
                children: [
                  for (final set in shown)
                    SizedBox(
                      width: 280,
                      child: EvidenceReadinessCard(
                        set: set,
                        readiness: service.readinessFor(set),
                        onOpen: () => context.go('/evidence/${set.id}'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: T.s16),
              Align(
                alignment: Alignment.centerLeft,
                child: PillButton(
                  label: 'See the full O-1 / EB-1 tracker',
                  variant: PillVariant.ink,
                  trailingIcon: Icons.arrow_forward,
                  onPressed: () => context.go('/evidence'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.child,
    required this.mobile,
    this.action,
    this.flex = 1,
    this.onTitleTap,
  });

  final String title;
  final Widget child;
  final bool mobile;

  /// The endpoint that will populate this panel — visible while the backend is
  /// still a spec, so the wiring is obvious rather than implied.
  final String? action;
  final int flex;

  /// When set, the title becomes a link to a fuller view of this panel's data.
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final titleText = Text(title, style: AppTheme.headingSm);
    final panel = Container(
      padding: const EdgeInsets.all(T.s24),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rFeatureCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: onTitleTap == null
                    ? titleText
                    : InkWell(
                        onTap: onTitleTap,
                        child: titleText,
                      ),
              ),
              if (action != null)
                Tooltip(
                  message: 'Populated by $action',
                  child: const Icon(
                    Icons.cloud_queue,
                    size: 14,
                    color: T.pencilGray,
                  ),
                ),
            ],
          ),
          const SizedBox(height: T.s16),
          child,
        ],
      ),
    );
    return mobile ? panel : Expanded(flex: flex, child: panel);
  }
}
