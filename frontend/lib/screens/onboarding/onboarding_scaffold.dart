import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// The shared frame for both onboarding steps.
///
/// Deliberately barer than the rest of the app: no site nav, no footer, no
/// marketing copy. One question fills the screen, the progress bar says how
/// much is left, and there is always a visible way out. Nothing here counts
/// down or times out.
class OnboardingScaffold extends StatelessWidget {
  const OnboardingScaffold({
    super.key,
    required this.step,
    required this.totalSteps,
    required this.title,
    required this.child,
    this.subtitle,
    this.progressNote,
    this.onBack,
    this.footer,
  });

  /// 1-based. Shown as "Step 1 of 2".
  final int step;
  final int totalSteps;

  final String title;
  final String? subtitle;

  /// The finer-grained position inside a step, e.g. "question 2 of 3".
  final String? progressNote;

  final VoidCallback? onBack;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);
    final progress = (step / totalSteps).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: T.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: mobile ? T.s24 : T.s32,
                vertical: T.s40,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (onBack != null)
                        _BackLink(onTap: onBack!)
                      else
                        const SizedBox(height: 32),
                      const Spacer(),
                      Text(
                        [
                          'Step $step of $totalSteps',
                          ?progressNote,
                        ].join(' · '),
                        style: AppTheme.caption,
                      ),
                    ],
                  ),
                  const SizedBox(height: T.s8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(T.rPill),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: progress),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOut,
                      builder: (context, value, _) => LinearProgressIndicator(
                        value: value,
                        minHeight: 6,
                        backgroundColor: T.skyWash.withValues(alpha: 0.45),
                        valueColor: const AlwaysStoppedAnimation(T.signalBlue),
                      ),
                    ),
                  ),
                  const SizedBox(height: T.s40),
                  Text(title, style: AppTheme.headingLg(context)),
                  if (subtitle != null) ...[
                    const SizedBox(height: T.s16),
                    Text(subtitle!, style: AppTheme.subheading),
                  ],
                  const SizedBox(height: T.s32),
                  child,
                  if (footer != null) ...[
                    const SizedBox(height: T.s32),
                    footer!,
                  ],
                  const SizedBox(height: T.s24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackLink extends StatelessWidget {
  const _BackLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            // A generous target — this is the escape hatch, so it must be easy
            // to hit without being the loudest thing on the screen.
            padding: const EdgeInsets.only(
              top: T.s8,
              bottom: T.s8,
              right: T.s16,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_back, size: 16, color: T.graphite),
                const SizedBox(width: 6),
                Text('Back', style: AppTheme.label),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
