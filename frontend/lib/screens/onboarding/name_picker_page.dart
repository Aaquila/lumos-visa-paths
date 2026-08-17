import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/onboarding_profile.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/cartoon_avatar.dart';
import 'onboarding_scaffold.dart';

/// Onboarding step 1: "What should I call you?"
///
/// Three cards, one tap, done. There is no text field on this screen by
/// design — asking somebody to invent and type a name is a decision plus a
/// keyboard plus a fear of getting it wrong, and none of that is worth
/// anything here. The handle is not a legal name and the copy says so.
class NamePickerPage extends StatefulWidget {
  const NamePickerPage({super.key, this.isChange = false});

  /// Reached from a settings entry point rather than from sign-up, so it
  /// returns to the dashboard instead of moving on to step 2.
  final bool isChange;

  @override
  State<NamePickerPage> createState() => _NamePickerPageState();
}

class _NamePickerPageState extends State<NamePickerPage> {
  late String? _selected = AuthService.instance.onboarding.chosenNameId;
  bool _busy = false;

  Future<void> _pick(NameChoice choice) async {
    if (_busy) return;
    setState(() {
      _selected = choice.id;
      _busy = true;
    });
    await AuthService.instance.chooseName(choice.id);
    if (!mounted) return;
    context.go(widget.isChange ? '/dashboard' : '/onboarding/situation');
  }

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    // Built inline rather than in a Builder: `Expanded` only works as a direct
    // child of the Flex.
    final children = <Widget>[];
    for (var i = 0; i < NameChoice.options.length; i++) {
      if (i > 0) {
        children.add(
          mobile ? const SizedBox(height: T.s16) : const SizedBox(width: T.s16),
        );
      }
      final choice = NameChoice.options[i];
      final card = _NameCard(
        choice: choice,
        selected: _selected == choice.id,
        onTap: () => _pick(choice),
      );
      children.add(mobile ? card : Expanded(child: card));
    }

    return OnboardingScaffold(
      step: 1,
      totalSteps: 2,
      title: 'What should I call you?',
      subtitle:
          'Pick a name. It\'s just what I\'ll call you — doesn\'t have to be '
          'your real one. You can swap it anytime.',
      onBack: widget.isChange ? () => context.go('/dashboard') : null,
      footer: Text(
        'No wrong answers. Nothing you pick is shown to anyone else.',
        style: AppTheme.bodySm,
      ),
      child: Flex(
        direction: mobile ? Axis.vertical : Axis.horizontal,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _NameCard extends StatefulWidget {
  const _NameCard({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final NameChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NameCard> createState() => _NameCardState();
}

class _NameCardState extends State<_NameCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hover;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: 'Call me ${widget.choice.name}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            // A deliberately oversized target: this is the first thing anybody
            // touches, and it should be impossible to miss or mis-tap.
            constraints: const BoxConstraints(minHeight: 220),
            padding: const EdgeInsets.symmetric(
              horizontal: T.s24,
              vertical: T.s32,
            ),
            decoration: BoxDecoration(
              color: widget.selected
                  ? CartoonAvatar.fillFor(
                      widget.choice.avatar,
                    ).withValues(alpha: 0.35)
                  : T.paper,
              border: active
                  ? Border.all(color: T.signalBlue, width: 2)
                  : Border.fromBorderSide(T.hairline),
              borderRadius: BorderRadius.circular(T.rFeatureCard),
              boxShadow: active ? T.floatShadow : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ExcludeSemantics(
                  child: CartoonAvatar(
                    kind: widget.choice.avatar,
                    size: 92,
                    selected: widget.selected,
                  ),
                ),
                const SizedBox(height: T.s16),
                Text(
                  widget.choice.name,
                  style: AppTheme.headingSm,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.choice.blurb,
                  style: AppTheme.bodySm,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
