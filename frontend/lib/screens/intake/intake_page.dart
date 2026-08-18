import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/case_profile.dart';
import '../../models/intake_questionnaire.dart';
import '../../models/pathway_graph.dart';
import '../../services/auth_service.dart';
import '../../services/case_service.dart';
import '../../services/pathway_repository.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/site_footer.dart';
import '../../widgets/site_nav.dart';
import '../../widgets/voice_input_button.dart';

/// "Where am I, and where do I want to be?" — the step that turns a person into
/// a position on the map.
///
/// Two ways in, and the page picks the order rather than making the user guess:
///
///  * **Describe it** posts free text to `POST /api/case/intake`, where a
///    reasoning agent places it on the graph. Offered first when the backend
///    reports a configured model.
///  * **Answer questions** walks the built-in [Questionnaire] locally. Always
///    available, works with the backend switched off, and never sends anything.
///
/// Either way the result is a *proposal*. Nothing is stored until the person
/// presses "Use this as my pathway".
class IntakePage extends StatefulWidget {
  const IntakePage({super.key, this.startInQuestionnaire = false});

  /// Deep-link straight into the questions (`/intake?mode=questions`).
  final bool startInQuestionnaire;

  @override
  State<IntakePage> createState() => _IntakePageState();
}

enum _Mode { describe, questions, edit }

class _IntakePageState extends State<IntakePage> {
  late final Future<PathwayGraph> _graph = PathwayRepository.instance.load();

  IntakeCapability? _capability;
  _Mode? _mode;

  final _situation = TextEditingController();
  final _goal = TextEditingController();
  final _clarify = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Questionnaire walk: the steps visited and the answers given, so "Back"
  /// is a pop rather than a re-derivation.
  final List<String> _stepIds = [Questionnaire.statusRoot];
  final List<IntakeOption> _statusPath = [];
  final List<IntakeOption> _goalPath = [];
  bool _askingGoal = false;

  CaseProfile? _result;

  /// True when the describe box was filled from what onboarding already asked,
  /// so the page can say where the words came from rather than appearing to
  /// have typed them itself.
  bool _prefilled = false;

  /// True when onboarding provided a comprehensive status answer that should
  /// be confirmed rather than re-asked.
  bool _statusFromOnboarding = false;

  /// True when onboarding provided a comprehensive goal answer that should
  /// be confirmed rather than re-asked.
  bool _goalFromOnboarding = false;

  @override
  void initState() {
    super.initState();
    _prefillFromOnboarding();
    if (widget.startInQuestionnaire) _mode = _Mode.questions;
    CaseService.instance.capability().then((capability) {
      if (!mounted) return;
      setState(() => _capability = capability);
    });
  }

  @override
  void dispose() {
    _situation.dispose();
    _goal.dispose();
    _clarify.dispose();
    super.dispose();
  }

  /// Onboarding is the front door; intake is the room behind it.
  ///
  /// Step 2 already asked, in plain words, what somebody is on and where they
  /// want to get to — asking again here would be a second intake wearing a
  /// different hat. So those answers are carried straight into the describe
  /// box, editable, and the page opens on that path when there is something to
  /// send. The questionnaire is untouched: it resolves to real node ids, which
  /// free text alone cannot, so it stays as the offline route and the fallback.
  void _prefillFromOnboarding() {
    final situation = AuthService.instance.onboarding.situation;
    if (situation == null || situation.isEmpty) return;

    final status = [
      situation.statusSummary,
      situation.dateSummary,
    ].where((line) => line.trim().isNotEmpty).join(' ');

    if (status.isEmpty && !situation.hasGoal) return;

    _situation.text = status;
    _goal.text = situation.goalSummary;
    _prefilled = true;
    if (status.isNotEmpty) _mode = _Mode.describe;
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _submitDescription() async {
    final text = _situation.text.trim();
    if (text.length < 12) {
      setState(
        () => _error =
            'Tell us a bit more — a sentence or two about your situation.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await CaseService.instance.resolveFromText(
        text,
        goal: _goal.text,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } on IntakeException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _choose(IntakeOption option) {
    setState(() {
      (_askingGoal ? _goalPath : _statusPath).add(option);

      if (option.next != null) {
        _stepIds.add(option.next!);
        return;
      }
      if (!_askingGoal) {
        _askingGoal = true;
        _stepIds.add(Questionnaire.goalRoot);
        return;
      }
      _result = Questionnaire.resolve(
        statusPath: _statusPath,
        goalPath: _goalPath,
      );
    });
  }

  void _back() {
    setState(() {
      if (_stepIds.length <= 1) {
        _mode = null;
        return;
      }
      _stepIds.removeLast();
      if (_askingGoal && _goalPath.isNotEmpty) {
        _goalPath.removeLast();
      } else if (_askingGoal) {
        _askingGoal = false;
        if (_statusPath.isNotEmpty) _statusPath.removeLast();
      } else if (_statusPath.isNotEmpty) {
        _statusPath.removeLast();
      }
    });
  }

  void _restart({_Mode? mode}) {
    setState(() {
      _result = null;
      _error = null;
      _stepIds
        ..clear()
        ..add(Questionnaire.statusRoot);
      _statusPath.clear();
      _goalPath.clear();
      _askingGoal = false;
      _mode = mode;
      _initOnboardingSkips();
    });
  }

  /// Check if onboarding provided comprehensive answers that can skip the
  /// questionnaire root questions.
  void _initOnboardingSkips() {
    final situation = AuthService.instance.onboarding.situation;
    if (situation == null) return;

    _statusFromOnboarding = situation.hasComprehensiveStatus;
    _goalFromOnboarding = situation.hasComprehensiveGoal;
  }

  Future<void> _accept(CaseProfile profile) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final goRouter = GoRouter.of(context);

    await CaseService.instance.save(profile);
    if (!mounted) return;

    final graph = await _graph;
    final currentNode = profile.currentNodeId != null
        ? graph.node(profile.currentNodeId!)
        : null;
    final goalNode =
        profile.goalNodeId != null ? graph.node(profile.goalNodeId!) : null;

    final currentName = currentNode?.name ?? 'your current status';
    final goalName = goalNode?.name ?? 'your goal';

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(
          'Updated your pathway\nYou are here: $currentName\nYou want to be: $goalName',
        ),
        duration: const Duration(seconds: 3),
        backgroundColor: T.signalBlue,
      ),
    );

    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    goRouter.go('/dashboard');
  }

  /// The free-text path can resolve to the O-1 umbrella node without knowing
  /// which category applies — this narrows it to the leaf the evidence
  /// tracker actually scores against.
  void _narrowO1(String nodeId) {
    final result = _result;
    if (result == null) return;
    setState(() {
      _result = result.copyWith(
        currentNodeId: result.currentNodeId == 'extraordinary.o1'
            ? nodeId
            : null,
        goalNodeId: result.goalNodeId == 'extraordinary.o1' ? nodeId : null,
      );
    });
  }

  /// Swaps a listed "also fits" alternative in as the goal, and puts the
  /// previous goal back on the alternatives list so the swap is reversible.
  void _selectGoal(String nodeId) {
    final result = _result;
    if (result == null || nodeId == result.goalNodeId) return;
    setState(() {
      final previous = result.goalNodeId;
      _result = result.copyWith(
        goalNodeId: nodeId,
        goalConfidence: 'high',
        alternativeGoalIds: [
          ?previous,
          for (final id in result.alternativeGoalIds) if (id != nodeId) id,
        ],
      );
    });
  }

  /// Answers the "still open" questions in free text and re-resolves rather
  /// than starting over — the person already got most of the way there.
  Future<void> _submitClarification() async {
    final addition = _clarify.text.trim();
    if (addition.isEmpty) return;

    final currentIteration = _result?.clarificationIteration ?? 1;

    final combined = [
      _situation.text.trim(),
      addition,
    ].where((s) => s.isNotEmpty).join('. ');

    setState(() {
      _situation.text = combined;
      _clarify.clear();
    });

    // Submit and increment iteration
    await _submitDescription();

    // Increment clarification iteration on the result
    if (_result != null && mounted) {
      setState(() {
        _result = _result!.copyWith(
          clarificationIteration: currentIteration + 1,
        );
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    return Scaffold(
      backgroundColor: T.paper,
      body: Column(
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
                        constraints: const BoxConstraints(maxWidth: 860),
                        child: FutureBuilder<PathwayGraph>(
                          future: _graph,
                          builder: (context, snapshot) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const StepBadge(
                                step: 'Intake',
                                descriptor:
                                    'where you are · where you want to be',
                              ),
                              const SizedBox(height: T.s16),
                              Text(
                                _result != null
                                    ? 'Here is where that puts you.'
                                    : 'Let\'s place you on the map.',
                                style: AppTheme.headingLg(context),
                              ),
                              const SizedBox(height: T.s16),
                              Text(
                                _result != null
                                    ? 'Check it before you keep it. Nothing '
                                          'saves until you say so.'
                                    : 'Two ways in, and neither is a form full '
                                          'of dates. Answers stay on this '
                                          'device unless you use the describe-'
                                          'it-yourself path, which sends that '
                                          'text to the intake service.',
                                style: AppTheme.subheading,
                              ),
                              const SizedBox(height: T.s32),
                              ..._body(context, snapshot.data),
                            ],
                          ),
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
      ),
    );
  }

  List<Widget> _body(BuildContext context, PathwayGraph? graph) {
    final result = _result;
    if (result != null) {
      return [
        _ResultCard(
          profile: result,
          graph: graph,
          onAccept: () => _accept(result),
          onRedo: () => setState(() => _mode = _Mode.edit),
          onNarrowO1: _narrowO1,
          onSelectGoal: _selectGoal,
          clarifyController: _clarify,
          busy: _busy,
          onClarify: _submitClarification,
          clarifyError: _error,
        ),
      ];
    }

    return switch (_mode) {
      null => [_chooser(context)],
      _Mode.describe => [_describeForm(context)],
      _Mode.questions => [_questionCard(context)],
      _Mode.edit => [_editAnswersCard(context)],
    };
  }

  Widget _chooser(BuildContext context) {
    final capability = _capability;
    final agentReady = capability?.llmAvailable ?? false;
    final mobile = Breaks.isMobile(context);

    final describe = _ModeCard(
      icon: Icons.chat_bubble_outline,
      fill: T.pastelSky,
      title: 'Describe it in your own words',
      body: agentReady
          ? 'Write it the way you would say it out loud. An agent reads it, '
                'places you on the map, and says what it still needs to know.'
          : 'Needs the intake service running with a reasoning model. '
                'Without one it only matches keywords, so the questions are '
                'the better path.',
      action: agentReady ? 'Write it out' : 'Try it anyway',
      recommended: agentReady,
      muted: !agentReady,
      onTap: () => setState(() => _mode = _Mode.describe),
      footnote: switch (capability) {
        null => 'Checking the intake service…',
        IntakeCapability(reachable: false) => 'Intake service not reachable.',
        IntakeCapability(llmAvailable: true, model: final m) =>
          'Reasoning with ${m ?? 'the configured model'}.',
        _ => 'Service running, no reasoning model configured.',
      },
    );

    final questions = _ModeCard(
      icon: Icons.checklist_rtl,
      fill: T.pastelMint,
      title: 'Answer a few questions',
      body:
          'Six taps or fewer. Runs entirely in this app — no service, no API '
          'key, nothing leaves your device.',
      action: 'Start the questions',
      recommended: !agentReady,
      onTap: () => setState(() => _mode = _Mode.questions),
      footnote: 'Always available.',
    );

    return Flex(
      direction: mobile ? Axis.vertical : Axis.horizontal,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mobile) ...[
          if (agentReady) describe else questions,
          const SizedBox(height: T.s16),
          if (agentReady) questions else describe,
        ] else ...[
          Expanded(child: agentReady ? describe : questions),
          const SizedBox(width: T.s24),
          Expanded(child: agentReady ? questions : describe),
        ],
      ],
    );
  }

  Widget _describeForm(BuildContext context) {
    return _Panel(
      title: 'In your own words',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_prefilled) ...[
            _Note(
              icon: Icons.auto_awesome,
              text: 'This is what you told me during setup. Edit it, or leave it as is.',
            ),
            const SizedBox(height: T.s16),
          ],
          Text(
            'What is your situation today? Include what you know — your '
            'status, what you have filed, your employer or family sponsor, '
            'roughly when things happened.',
            style: AppTheme.bodySm,
          ),
          const SizedBox(height: T.s16),
          _Field(
            controller: _situation,
            hint:
                'I finished my MS in May and I am on OPT. My employer wants to '
                'file an H-1B next spring.',
            maxLines: 6,
            enabled: !_busy,
            voiceLabel: 'your situation today',
          ),
          const SizedBox(height: T.s24),
          Text('Where do you want to end up?', style: AppTheme.label),
          const SizedBox(height: 6),
          Text(
            'Optional — a direction is enough: "stay long term", '
            '"citizenship eventually", "back home in a few years".',
            style: AppTheme.caption,
          ),
          const SizedBox(height: T.s8),
          _Field(
            controller: _goal,
            hint: 'A green card through my job, eventually.',
            maxLines: 2,
            enabled: !_busy,
            voiceLabel: 'where you want to end up',
            // The note above this one already said where the audio goes.
            voiceDisclosure: false,
          ),
          if (_error != null) ...[
            const SizedBox(height: T.s16),
            _Note(icon: Icons.error_outline, text: _error!),
          ],
          const SizedBox(height: T.s24),
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              PillButton(
                label: _busy
                    ? 'Reading your situation…'
                    : 'Place me on the map',
                variant: PillVariant.signal,
                trailingIcon: Icons.arrow_forward,
                busy: _busy,
                onPressed: _busy ? null : _submitDescription,
              ),
              PillButton(
                label: 'Answer questions instead',
                icon: Icons.checklist_rtl,
                onPressed: _busy ? null : () => _restart(mode: _Mode.questions),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _questionCard(BuildContext context) {
    final situation = AuthService.instance.onboarding.situation;

    // Show confirmation if this is the first question and we have onboarding answers
    if (!_askingGoal &&
        _stepIds.length == 1 &&
        _statusPath.isEmpty &&
        situation != null &&
        _statusFromOnboarding) {
      return _confirmationCard(
        context,
        title: 'Where you are',
        message: 'I found this in your setup answers:',
        answer: situation.statusSummary,
        onConfirm: () {
          setState(() {
            // Mark status as confirmed and move to goal
            _statusPath.add(const IntakeOption(label: 'Confirmed from onboarding'));
            _askingGoal = true;
            _stepIds.add(Questionnaire.goalRoot);
          });
        },
        onEdit: () {
          // User said "no", proceed with normal questionnaire
          setState(() => _statusFromOnboarding = false);
        },
      );
    }

    // Show goal confirmation if we have it and are now asking goal
    if (_askingGoal &&
        _goalPath.isEmpty &&
        situation != null &&
        _goalFromOnboarding &&
        _statusPath.isNotEmpty) {
      return _confirmationCard(
        context,
        title: 'Where you want to be',
        message: 'I found this in your setup answers:',
        answer: situation.goalSummary,
        onConfirm: () {
          setState(() {
            // Mark goal as confirmed and resolve
            _goalPath.add(const IntakeOption(label: 'Confirmed from onboarding'));
            _result = Questionnaire.resolve(
              statusPath: _statusPath,
              goalPath: _goalPath,
            );
          });
        },
        onEdit: () {
          // User said "no", proceed with normal questionnaire for goal
          setState(() => _goalFromOnboarding = false);
        },
      );
    }

    // Normal questionnaire flow
    final step = Questionnaire.step(_stepIds.last);

    return _Panel(
      title: _askingGoal ? 'Where you want to be' : 'Where you are',
      trailing: Text('Step ${_stepIds.length}', style: AppTheme.caption),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step.prompt, style: AppTheme.headingSm),
          if (step.hint != null) ...[
            const SizedBox(height: 6),
            Text(step.hint!, style: AppTheme.bodySm),
          ],
          const SizedBox(height: T.s16),
          for (final option in step.options) ...[
            _OptionRow(option: option, onTap: () => _choose(option)),
            const SizedBox(height: T.s8),
          ],
          const SizedBox(height: T.s8),
          Row(
            children: [
              PillButton(
                label: 'Back',
                icon: Icons.arrow_back,
                onPressed: _back,
              ),
              const Spacer(),
              if (_askingGoal)
                PillButton(
                  label: 'Skip the goal',
                  onPressed: () => setState(() {
                    _result = Questionnaire.resolve(
                      statusPath: _statusPath,
                      goalPath: const [],
                    );
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _confirmationCard(
    BuildContext context, {
    required String title,
    required String message,
    required String answer,
    required VoidCallback onConfirm,
    required VoidCallback onEdit,
  }) {
    return _Panel(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: AppTheme.bodySm),
          const SizedBox(height: T.s8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(T.s16),
            decoration: BoxDecoration(
              color: T.skyWash.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(T.rInput),
              border: Border.fromBorderSide(T.hairline),
            ),
            child: Text(answer, style: AppTheme.body),
          ),
          const SizedBox(height: T.s24),
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              PillButton(
                label: 'Yes, that\'s right',
                icon: Icons.check_circle_outline,
                variant: PillVariant.signal,
                onPressed: onConfirm,
              ),
              PillButton(
                label: 'No, let me correct it',
                onPressed: onEdit,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _editAnswersCard(BuildContext context) {
    final result = _result;
    final graph = _graph;
    if (result == null) return const SizedBox();

    return FutureBuilder<PathwayGraph>(
      future: graph,
      builder: (context, snapshot) {
        final graph = snapshot.data;
        final currentNode = result.currentNodeId != null
            ? graph?.node(result.currentNodeId!)
            : null;
        final goalNode = result.goalNodeId != null
            ? graph?.node(result.goalNodeId!)
            : null;

        return _Panel(
          title: 'Edit Your Answers',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // What intake understood section
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(T.s16),
                decoration: BoxDecoration(
                  color: T.skyWash.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(T.rInput),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('What intake understood', style: AppTheme.label),
                    const SizedBox(height: T.s8),
                    if (currentNode != null) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('You are here',
                                    style: AppTheme.bodySm.copyWith(
                                      color: T.pencilGray,
                                    )),
                                const SizedBox(height: T.s4),
                                Text(currentNode.name, style: AppTheme.body),
                              ],
                            ),
                          ),
                          const SizedBox(width: T.s8),
                          PillButton(
                            label: 'Change',
                            onPressed: () => setState(() {
                              _mode = null;
                              _result = null;
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: T.s8),
                    ],
                    if (goalNode != null) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('You want to be',
                                    style: AppTheme.bodySm.copyWith(
                                      color: T.pencilGray,
                                    )),
                                const SizedBox(height: T.s4),
                                Text(goalNode.name, style: AppTheme.body),
                              ],
                            ),
                          ),
                          const SizedBox(width: T.s8),
                          PillButton(
                            label: 'Change',
                            onPressed: () => setState(() {
                              _mode = null;
                              _result = null;
                            }),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Still Open questions section
              if (result.questions.isNotEmpty) ...[
                const SizedBox(height: T.s24),
                Text('Still open (clarify these)',
                    style: AppTheme.label),
                const SizedBox(height: T.s8),
                Text(
                  'Answer any of these to raise confidence:',
                  style: AppTheme.bodySm,
                ),
                const SizedBox(height: T.s8),
                for (final q in result.questions) ...[
                  _Note(icon: Icons.help_outline, text: q),
                  const SizedBox(height: T.s8),
                ],
                _Field(
                  controller: _clarify,
                  hint: 'Answer any of the above in your own words.',
                  maxLines: 3,
                  enabled: !_busy,
                  voiceLabel: 'your answer',
                ),
                const SizedBox(height: T.s16),
                PillButton(
                  label: _busy ? 'Updating…' : 'Update with these answers',
                  variant: PillVariant.signal,
                  icon: Icons.check,
                  busy: _busy,
                  onPressed: _busy ? null : _submitClarification,
                ),
              ],

              if (result.questions.isEmpty) ...[
                const SizedBox(height: T.s24),
                Text(
                  'No open questions. Your answers look complete.',
                  style: AppTheme.body,
                ),
              ],

              const SizedBox(height: T.s16),
              Row(
                children: [
                  PillButton(
                    label: 'Back',
                    icon: Icons.arrow_back,
                    onPressed: () =>
                        setState(() => _mode = null),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Pieces ──────────────────────────────────────────────────────────────────

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s32),
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
                child: Text(
                  title.toUpperCase(),
                  style: AppTheme.badge.copyWith(
                    color: T.pencilGray,
                    letterSpacing: 1,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: T.s16),
          child,
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.fill,
    required this.title,
    required this.body,
    required this.action,
    required this.onTap,
    required this.footnote,
    this.recommended = false,
    this.muted = false,
  });

  final IconData icon;
  final Color fill;
  final String title;
  final String body;
  final String action;
  final VoidCallback onTap;
  final String footnote;
  final bool recommended;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.s24),
      decoration: BoxDecoration(
        color: T.paper,
        border: recommended
            ? Border.all(color: T.signalBlue, width: 2)
            : Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rFeatureCard),
        boxShadow: recommended ? T.floatShadow : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PastelIconBadge(icon: icon, fill: fill, size: 36),
              const Spacer(),
              if (recommended)
                Text(
                  'SUGGESTED',
                  style: AppTheme.badge.copyWith(
                    color: T.signalBlue,
                    letterSpacing: 1,
                  ),
                ),
            ],
          ),
          const SizedBox(height: T.s16),
          Text(title, style: AppTheme.headingSm),
          const SizedBox(height: T.s8),
          Text(body, style: AppTheme.bodySm),
          const SizedBox(height: T.s16),
          PillButton(
            label: action,
            variant: muted ? PillVariant.outline : PillVariant.ink,
            trailingIcon: Icons.arrow_forward,
            onPressed: onTap,
          ),
          const SizedBox(height: T.s8),
          Text(footnote, style: AppTheme.caption),
        ],
      ),
    );
  }
}

class _OptionRow extends StatefulWidget {
  const _OptionRow({required this.option, required this.onTap});

  final IntakeOption option;
  final VoidCallback onTap;

  @override
  State<_OptionRow> createState() => _OptionRowState();
}

class _OptionRowState extends State<_OptionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: T.s16, vertical: 14),
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFFF5F7F9) : T.paper,
            border: Border.all(
              color: _hover ? T.signalBlue : T.pencilGray,
              width: _hover ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(T.rInput),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.option.label,
                  style: AppTheme.label.copyWith(color: T.ink),
                ),
              ),
              Icon(
                widget.option.isTerminal
                    ? Icons.check_circle_outline
                    : Icons.chevron_right,
                size: 18,
                color: _hover ? T.signalBlue : T.pencilGray,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A text box that can also be spoken into.
///
/// The describe path asks for a paragraph written "the way you would say it out
/// loud", which is a lot of typing for someone doing this on a phone, in a
/// second language, or at the end of a bad week — so [voiceLabel] hangs a
/// microphone under the box. What it hears is appended as ordinary editable
/// text and never submitted for them; pressing "Place me on the map" stays a
/// separate, deliberate act. On browsers with no speech recognition the
/// microphone row is simply not built.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.enabled = true,
    this.voiceLabel,
    this.voiceDisclosure = true,
  });

  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final bool enabled;

  /// Plain-language name of this box. Null leaves the field text-only.
  final String? voiceLabel;

  /// Whether this field carries the where-the-audio-goes note. Only the first
  /// microphone on a screen needs to say it.
  final bool voiceDisclosure;

  @override
  Widget build(BuildContext context) {
    final label = voiceLabel;

    // Names the box for a screen reader. The role stays with the TextField
    // itself; this only supplies the label the decoration does not.
    final field = Semantics(
      enabled: enabled,
      label: label == null ? null : 'In your own words: $label',
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        enabled: enabled,
        style: AppTheme.body.copyWith(color: T.ink),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppTheme.body.copyWith(color: T.pencilGray),
          filled: true,
          fillColor: enabled ? T.paper : const Color(0xFFF5F7F9),
          contentPadding: const EdgeInsets.all(T.s16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInput),
            borderSide: T.hairline,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInput),
            borderSide: T.hairline,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInput),
            borderSide: const BorderSide(color: T.signalBlue, width: 1.5),
          ),
        ),
      ),
    );

    if (label == null) return field;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field,
        const SizedBox(height: T.s8),
        VoiceInputButton(
          controller: controller,
          fieldLabel: label,
          enabled: enabled,
          showDisclosure: voiceDisclosure,
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 15, color: color ?? T.pencilGray),
        ),
        const SizedBox(width: T.s8),
        Expanded(child: Text(text, style: AppTheme.bodySm)),
      ],
    );
  }
}

/// The proposal: what intake believes, what it is unsure about, and the two
/// buttons that decide whether it becomes the person's case.
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.profile,
    required this.graph,
    required this.onAccept,
    required this.onRedo,
    required this.onNarrowO1,
    required this.onSelectGoal,
    required this.clarifyController,
    required this.busy,
    required this.onClarify,
    this.clarifyError,
  });

  final CaseProfile profile;
  final PathwayGraph? graph;
  final VoidCallback onAccept;
  final VoidCallback onRedo;
  final ValueChanged<String> onNarrowO1;

  /// Swaps an "also fits" alternative in as the goal.
  final ValueChanged<String> onSelectGoal;

  final TextEditingController clarifyController;
  final bool busy;
  final VoidCallback onClarify;
  final String? clarifyError;

  bool get _needsO1Category =>
      profile.currentNodeId == 'extraordinary.o1' ||
      profile.goalNodeId == 'extraordinary.o1';

  @override
  Widget build(BuildContext context) {
    final current = graph?.node(profile.currentNodeId ?? '');
    final goal = graph?.node(profile.goalNodeId ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (profile.degraded)
          Padding(
            padding: const EdgeInsets.only(bottom: T.s16),
            child: _Banner(
              icon: Icons.cloud_off,
              text:
                  'The reasoning agent could not be reached, so this is a plain '
                  'keyword match — a starting point. Use the questions if it '
                  'looks wrong.',
            ),
          ),

        if (_needsO1Category) ...[
          _O1CategoryPrompt(onChoose: onNarrowO1),
          const SizedBox(height: T.s16),
        ],

        _NodeCard(
          label: 'You are here',
          node: current,
          confidence: profile.currentConfidence,
          emptyText:
              'Intake could not identify your current status from what it was '
              'given. Not a verdict — the questions below will settle it.',
          accent: T.signalBlue,
        ),
        const SizedBox(height: T.s16),
        _NodeCard(
          label: 'You want to be here',
          node: goal,
          confidence: profile.goalConfidence,
          emptyText:
              'No destination recorded. The map will show everything open to '
              'you instead of narrowing to one route.',
          accent: T.voltageViolet,
          alternatives: [
            for (final id in profile.alternativeGoalIds)
              (id: id, name: graph?.node(id)?.name ?? id),
          ],
          onSelectAlternative: onSelectGoal,
        ),

        if (profile.explanation.isNotEmpty) ...[
          const SizedBox(height: T.s16),
          _Panel(
            title: profile.source.label,
            child: Text(profile.explanation, style: AppTheme.body),
          ),
        ],

        if (profile.questions.isNotEmpty) ...[
          const SizedBox(height: T.s16),
          _Panel(
            title: () {
              if (profile.clarificationIteration >= 2) {
                return 'Still clarifying';
              }
              return 'I need some info';
            }(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Answering these would raise the confidence above. Shown, '
                  'not assumed.',
                  style: AppTheme.bodySm,
                ),
                const SizedBox(height: T.s16),
                for (final q in profile.questions) ...[
                  _Note(icon: Icons.help_outline, text: q),
                  const SizedBox(height: T.s8),
                ],
                const SizedBox(height: T.s8),
                _Field(
                  controller: clarifyController,
                  hint: 'Answer any of the above in your own words.',
                  maxLines: 3,
                  enabled: !busy,
                  voiceLabel: 'your answer',
                ),
                if (clarifyError != null) ...[
                  const SizedBox(height: T.s8),
                  _Note(icon: Icons.error_outline, text: clarifyError!),
                ],
                const SizedBox(height: T.s8),
                Wrap(
                  spacing: T.s8,
                  runSpacing: T.s8,
                  children: [
                    PillButton(
                      label: busy ? 'Updating…' : 'Update my answer',
                      icon: Icons.check,
                      busy: busy,
                      onPressed: busy ? null : onClarify,
                    ),
                    if (profile.clarificationIteration >= 3)
                      PillButton(
                        label: 'Skip these questions',
                        icon: Icons.fast_forward_outlined,
                        onPressed: busy ? null : () {
                          // Accept current result without clarification
                          onAccept();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],

        if (profile.facts.isNotEmpty) ...[
          const SizedBox(height: T.s16),
          _Panel(
            title: 'What intake understood',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final fact in profile.facts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: T.s8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 130,
                          child: Text(fact.label, style: AppTheme.caption),
                        ),
                        Expanded(
                          child: Text(fact.value, style: AppTheme.bodySm),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],

        const SizedBox(height: T.s24),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            PillButton(
              label: 'Use this as my pathway',
              variant: PillVariant.signal,
              trailingIcon: Icons.arrow_forward,
              onPressed: onAccept,
            ),
            PillButton(
              label: 'Not right — answer the questions',
              icon: Icons.checklist_rtl,
              onPressed: onRedo,
            ),
            if (profile.currentNodeId != null)
              PillButton(
                label: 'Open it on the map',
                icon: Icons.map_outlined,
                onPressed: () =>
                    context.go('/visa-pathways?node=${profile.currentNodeId}'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Shown when a result resolves to the O-1 umbrella node rather than a
/// specific category — the evidence tracker scores against O-1A/O-1B, not the
/// umbrella, so this narrows it before the person accepts the pathway.
class _O1CategoryPrompt extends StatelessWidget {
  const _O1CategoryPrompt({required this.onChoose});

  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Which best describes your field?', style: AppTheme.bodySm),
          const SizedBox(height: T.s8),
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              PillButton(
                label: 'Sciences, education, business, or athletics',
                onPressed: () => onChoose('extraordinary.o1a'),
              ),
              PillButton(
                label: 'Arts, motion pictures, or television',
                onPressed: () => onChoose('extraordinary.o1b'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.label,
    required this.node,
    required this.confidence,
    required this.emptyText,
    required this.accent,
    this.alternatives = const [],
    this.onSelectAlternative,
  });

  final String label;
  final PathwayNode? node;
  final String confidence;
  final String emptyText;
  final Color accent;
  final List<({String id, String name})> alternatives;

  /// Taps an "also fits" pill to swap it in as the goal. Null leaves the
  /// pills as pure decoration (used for the current-status card, which has
  /// no alternatives).
  final ValueChanged<String>? onSelectAlternative;

  @override
  Widget build(BuildContext context) {
    final resolved = node != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s24),
      decoration: BoxDecoration(
        color: T.paper,
        border: resolved
            ? Border.all(color: accent, width: 2)
            : Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rFeatureCard),
        boxShadow: resolved ? T.floatShadow : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label.toUpperCase(),
                style: AppTheme.badge.copyWith(
                  color: resolved ? accent : T.pencilGray,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              if (resolved) _ConfidenceChip(confidence: confidence),
            ],
          ),
          const SizedBox(height: T.s8),
          Text(node?.name ?? 'Not identified', style: AppTheme.headingSm),
          const SizedBox(height: 6),
          Text(
            resolved ? node!.description : emptyText,
            style: AppTheme.bodySm,
          ),
          if (resolved && !node!.isModeled) ...[
            const SizedBox(height: T.s8),
            _Note(
              icon: Icons.construction,
              text:
                  'This family is on the map but not yet modelled in depth, so '
                  'deadlines and alerts are thinner than for the rest.',
            ),
          ],
          if (alternatives.isNotEmpty) ...[
            const SizedBox(height: T.s16),
            Text('Also fits', style: AppTheme.caption),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final alt in alternatives)
                  MetaPill(
                    label: alt.name,
                    onTap: onSelectAlternative == null
                        ? null
                        : () => onSelectAlternative!(alt.id),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfidenceChip extends StatelessWidget {
  const _ConfidenceChip({required this.confidence});

  final String confidence;

  @override
  Widget build(BuildContext context) {
    final (Color fill, String text) = switch (confidence) {
      'high' => (T.pastelMint, 'confident'),
      'medium' => (T.pastelYellow, 'fairly sure'),
      _ => (T.pastelPeach, 'a guess'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(T.rPill),
      ),
      child: Text(
        text,
        style: AppTheme.caption.copyWith(
          color: T.ink,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        color: T.pastelPeach.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(T.rInput),
      ),
      child: _Note(icon: icon, text: text, color: T.carbon),
    );
  }
}
