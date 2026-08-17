import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/hero_journey.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/reveal.dart';
import '../../widgets/site_footer.dart';
import '../../widgets/site_nav.dart';
import '../../widgets/wavy_cta.dart';

/// The page everyone lands on. Five sections, no filler: hero, why this exists,
/// what it does, what we never collect, and the way in.
class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  final _scroll = ScrollController();

  final _howKey = GlobalKey();

  /// Target of the skip link — focus lands here, on the hero, so the next Tab
  /// continues from the content rather than restarting at the nav.
  final _mainFocus = FocusNode(
    debugLabel: 'landing-main-content',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    LandingScrollBus.instance.anchors['how'] = _howKey;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _mainFocus.dispose();
    super.dispose();
  }

  void _skipToContent() {
    _scroll.jumpTo(0);
    _mainFocus.requestFocus();
  }

  void _getStarted() {
    // "Get started" means sign in — or, if the session is already live, go
    // straight to the personal page.
    context.go(AuthService.instance.isSignedIn ? '/dashboard' : '/signin');
  }

  void _viewPathways() => context.go('/visa-pathways');

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);
    final pad = mobile ? T.s24 : T.s32;

    return Scaffold(
      backgroundColor: T.paper,
      body: Column(
        children: [
          // First in the traversal order, before the nav: a keyboard user's
          // very first Tab offers to jump the whole navigation block. It is
          // invisible until focused, which is the standard pattern.
          _SkipToContentLink(onSkip: _skipToContent),
          const SiteNav(activeRoute: '/'),
          Expanded(
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                child: Column(
                  children: [
                    Focus(
                      focusNode: _mainFocus,
                      child: Semantics(
                        label: 'Main content',
                        container: true,
                        child: _Hero(
                          onGetStarted: _getStarted,
                          onViewPathways: _viewPathways,
                        ),
                      ),
                    ),
                    const SizedBox(height: T.sectionGap),
                    _Section(padding: pad, child: const _WhyThisExists()),
                    SizedBox(height: T.sectionGap, key: _howKey),
                    _Section(padding: pad, child: const _WhatItDoes()),
                    const SizedBox(height: T.sectionGap),
                    _Section(padding: pad, child: const _Privacy()),
                    const SizedBox(height: T.sectionGap),
                    _Section(
                      padding: pad,
                      child: _ClosingCta(onGetStarted: _getStarted),
                    ),
                    const SizedBox(height: T.s96),
                    const SiteFooter(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Skip to content": zero-height until it takes keyboard focus, then it
/// expands into a visible pill above the nav.
///
/// Without it, every keyboard and screen-reader visit to this page starts by
/// walking the wordmark, three nav links and two buttons before reaching a
/// single word of the page itself.
class _SkipToContentLink extends StatefulWidget {
  const _SkipToContentLink({required this.onSkip});

  final VoidCallback onSkip;

  @override
  State<_SkipToContentLink> createState() => _SkipToContentLinkState();
}

class _SkipToContentLinkState extends State<_SkipToContentLink> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Skip to main content',
      onTap: widget.onSkip,
      child: FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSkip();
              return null;
            },
          ),
        },
        child: ExcludeSemantics(
          // Collapsed rather than Offstage: an offstage subtree cannot hold
          // focus, which is the one thing this control exists to do.
          child: _focused
              ? Container(
                  width: double.infinity,
                  color: T.ink,
                  padding: const EdgeInsets.symmetric(
                    horizontal: T.s24,
                    vertical: T.s8,
                  ),
                  child: Text(
                    'Skip to main content',
                    style: AppTheme.label.copyWith(color: T.paper),
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ),
    );
  }
}

/// Columns share width on wide viewports and stack at their natural height on
/// narrow ones, where `Expanded` would be meaningless.
Widget _flexed({required bool mobile, required Widget child, int flex = 1}) =>
    mobile ? child : Expanded(flex: flex, child: child);

/// Max-width contained, centered — the page never goes full-bleed.
class _Section extends StatelessWidget {
  const _Section({required this.child, required this.padding});

  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padding),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.pageMaxWidth),
          child: child,
        ),
      ),
    );
  }
}

// ── Hero ────────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  const _Hero({required this.onGetStarted, required this.onViewPathways});

  final VoidCallback onGetStarted;
  final VoidCallback onViewPathways;

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        mobile ? T.s24 : T.s32,
        mobile ? T.s40 : T.s56,
        mobile ? T.s24 : T.s32,
        0,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.pageMaxWidth),
          child: Column(
            children: [
              Reveal(
                child: Text(
                  'LUMOS',
                  style: AppTheme.label.copyWith(
                    color: T.signalBlue,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                    fontSize: 45,
                  ),
                ),
              ),
              const SizedBox(height: T.s8),
              Reveal(
                delay: const Duration(milliseconds: 80),
                child: Text(
                  'Your immigration assistant',
                  textAlign: TextAlign.center,
                  style: AppTheme.displayXl(context),
                ),
              ),
              const SizedBox(height: T.s8),
              Reveal(
                delay: const Duration(milliseconds: 80),
                child: Text(
                  'for neurodivergent & struggling brains',
                  textAlign: TextAlign.center,
                  style: AppTheme.displayX2(
                    context,
                  ).copyWith(color: const Color.fromARGB(255, 32, 140, 248)),
                ),
              ),
              const SizedBox(height: T.s16),
              Reveal(
                delay: const Duration(milliseconds: 160),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Text(
                    'Immigration runs on deadlines you cannot afford to miss, '
                    'while you are also holding down work, school and a life. '
                    'Lumos holds the rest: your situation, your dates, the '
                    'news that affects you, and the paths still open.',
                    textAlign: TextAlign.center,
                    style: AppTheme.subheading,
                  ),
                ),
              ),
              // A light touch of air before the illustration — no card, no
              // border, just the journey itself at full width, wider than
              // the text above and below it. The rail sits low in its own
              // box already, so it needs little extra clearance up top.
              const SizedBox(height: T.s2),
              IgnorePointer(
                child: Reveal(
                  delay: const Duration(milliseconds: 180),
                  child: HeroJourney(height: mobile ? 130 : 160),
                ),
              ),
              const SizedBox(height: T.s2),
              Reveal(
                delay: const Duration(milliseconds: 260),
                child: Wrap(
                  spacing: T.s16,
                  runSpacing: T.s16,
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    WavyCta(
                      label: 'Get started',
                      icon: Icons.arrow_forward,
                      onPressed: onGetStarted,
                    ),
                    PillButton(
                      label: 'View visa pathways',
                      icon: Icons.account_tree_outlined,
                      large: true,
                      onPressed: onViewPathways,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: T.s16),
              Reveal(
                delay: const Duration(milliseconds: 300),
                child: Text(
                  'Google sign-in · No documents · No card',
                  style: AppTheme.caption,
                ),
              ),
              SizedBox(height: mobile ? T.s32 : T.s48),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Why this exists ─────────────────────────────────────────────────────────

class _WhyThisExists extends StatelessWidget {
  const _WhyThisExists();

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Reveal(
          child: StepBadge(
            step: 'Why you need this',
            descriptor: 'the honest version',
          ),
        ),
        const SizedBox(height: T.s24),
        Reveal(
          delay: const Duration(milliseconds: 60),
          child: Flex(
            direction: mobile ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _flexed(
                mobile: mobile,
                flex: 3,
                child: Text(
                  'If your brain does not do\ndeadlines, that is what\nwe are for.',
                  style: AppTheme.headingLg(context),
                ),
              ),
              const SizedBox(width: T.s48, height: T.s24),
              _flexed(
                mobile: mobile,
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Immigration asks you to track hard dates, read policy '
                      'language and act early, on top of a job, a degree, a '
                      'family, and everything else. '
                      'One missed window can cost years.',
                      style: AppTheme.body,
                    ),
                    const SizedBox(height: T.s16),
                    Text(
                      'Plenty of us do that while anxious, stretched thin, or '
                      'have a brain wired in a way that makes long-range planning harder. '
                      'ADHD/autism makes tracking harder. This solution helps the '
                      'design to be on your side.',
                      style: AppTheme.body,
                    ),
                    const SizedBox(height: T.s16),
                    Text(
                      'Lumos holds the state for you: remembers the '
                      'dates, shows only what is relevant, and cuts big '
                      'processes down to the one thing to do next.',
                      style: AppTheme.bodyHighlight,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── What it does ────────────────────────────────────────────────────────────

class _WhatItDoes extends StatelessWidget {
  const _WhatItDoes();

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);
    const items = [
      (
        'Understands your situation',
        'Describe where you stand in plain words no forms, no legal '
            'vocabulary. Lumos works out your actual status and shows you '
            'what it found before anything is saved.',
        Icons.chat_bubble_outline,
        T.pastelLavender,
      ),
      (
        'Keeps you ahead of deadlines',
        'Every date your status implies, in order, each with the plain '
            'reason it exists. What is urgent comes first; what is months '
            'away stays out of your way.',
        Icons.event_available_outlined,
        T.pastelPeach,
      ),
      (
        'Filters the news for you',
        'Not every immigration update needs your attention. Lumos scrapes '
            'all of it, then surfaces only the news that actually applies '
            'to your situation nothing unnecessary.',
        Icons.campaign_outlined,
        T.pastelMint,
      ),
      (
        'Maps the paths ahead',
        'Explore where each visa can lead, what switching types actually '
            'involves, and what to start building now — including the '
            'evidence an O-1 or EB-1 profile takes years to build.',
        Icons.account_tree_outlined,
        T.pastelPink,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Reveal(
          child: StepBadge(step: 'What it does', descriptor: 'four features'),
        ),
        const SizedBox(height: T.s16),
        Reveal(
          delay: const Duration(milliseconds: 60),
          child: Text(
            'Keep the clutter and chaos minimal',
            style: AppTheme.headingLg(context),
          ),
        ),
        const SizedBox(height: T.s24),
        Wrap(
          spacing: T.s16,
          runSpacing: T.s16,
          children: [
            for (var i = 0; i < items.length; i++)
              SizedBox(
                width: mobile ? double.infinity : 560,
                child: Reveal(
                  delay: Duration(milliseconds: 70 * i),
                  child: _Capability(
                    title: items[i].$1,
                    body: items[i].$2,
                    icon: items[i].$3,
                    accent: items[i].$4,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Capability extends StatelessWidget {
  const _Capability({
    required this.title,
    required this.body,
    required this.icon,
    required this.accent,
  });

  final String title;
  final String body;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.s32),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rFeatureCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PastelIconBadge(icon: icon, fill: accent),
          const SizedBox(height: T.s24),
          Text(title, style: AppTheme.headingSm),
          const SizedBox(height: T.s8),
          Text(body, style: AppTheme.bodySm),
        ],
      ),
    );
  }
}

// ── Privacy ─────────────────────────────────────────────────────────────────

class _Privacy extends StatelessWidget {
  const _Privacy();

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);
    const lines = [
      'No documents, ever. We never ask for, collect or store passports, I-20s, '
          'receipt notices, visas, or any files.',
      'No email, name, phone, address, or personal identifying information. Only '
          'your Google sign-in ID (anonymous and immutable).',
      'You describe your visa situation in plain text, your own words. That '
          'is all we store about you.',
      'Your visa status is between you and Lumos. Only you see your '
          'situation, your deadlines, and which news matters to you.',
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(mobile ? T.s24 : T.s48),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rFeatureCard),
      ),
      child: Reveal(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const StepBadge(step: 'Privacy', descriptor: 'plainly'),
            const SizedBox(height: T.s24),
            Text(
              'We do not want your documents.',
              style: AppTheme.headingLg(context),
            ),
            const SizedBox(height: T.s32),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: T.s16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.lock_outline,
                      size: 18,
                      color: T.signalBlue,
                    ),
                    const SizedBox(width: T.s16),
                    Expanded(child: Text(line, style: AppTheme.body)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Closing CTA ─────────────────────────────────────────────────────────────

class _ClosingCta extends StatelessWidget {
  const _ClosingCta({required this.onGetStarted});

  final VoidCallback onGetStarted;

  @override
  Widget build(BuildContext context) {
    return Reveal(
      child: Column(
        children: [
          Text(
            'Let something else\nkeep track.',
            textAlign: TextAlign.center,
            style: AppTheme.display(context),
          ),
          const SizedBox(height: T.s24),
          Text(
            'Sign in with Google, tell Lumos where you are in a few sentences, '
            'and it takes it from there.',
            textAlign: TextAlign.center,
            style: AppTheme.subheading,
          ),
          const SizedBox(height: T.s32),
          PillButton(
            label: 'Get started',
            variant: PillVariant.signal,
            trailingIcon: Icons.arrow_forward,
            large: true,
            onPressed: onGetStarted,
          ),
        ],
      ),
    );
  }
}
