import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The "supports, does not replace, a licensed immigration attorney" notice is
/// a persistent, visible element on every screen — never a one-time modal
/// (PROJECT_PRD §8.2, Frontend UI PRD §4).
class LegalDisclaimer extends StatelessWidget {
  const LegalDisclaimer({super.key, this.compact = false});

  final bool compact;

  static const text =
      'Lumos supports, and does not replace, a licensed immigration attorney. '
      'AI can make mistakes — every date, cap and fee is re-verified against '
      'its official source, but the decision is still yours to make with '
      'counsel.';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 12 : T.s16),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rInput),
      ),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Decorative: the scales-of-justice glyph adds nothing a reader
            // does not get from the notice itself.
            const ExcludeSemantics(
              child: Icon(
                Icons.balance_outlined,
                size: 16,
                color: T.pencilGray,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: (compact ? AppTheme.caption : AppTheme.bodySm).copyWith(
                  color: T.graphite,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SiteFooter extends StatelessWidget {
  const SiteFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final compact = Breaks.isMobile(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        compact ? T.s24 : T.s32,
        T.s64,
        compact ? T.s24 : T.s32,
        T.s40,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x338C9BAA))),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.pageMaxWidth),
          child: Semantics(
            explicitChildNodes: true,
            label: 'Site footer',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LegalDisclaimer(),
                const SizedBox(height: T.s16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const ExcludeSemantics(
                      child: Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: T.pencilGray,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Lumos stores no personal documents. The only identifying '
                        'information collected is your Google sign-in, which can '
                        'be anonymous.',
                        style: AppTheme.caption,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: T.s32),
                Wrap(
                  spacing: T.s32,
                  runSpacing: T.s16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('© 2026 Lumos', style: AppTheme.caption),
                    _FooterLink(
                      'Visa pathways',
                      () => context.go('/visa-pathways'),
                    ),
                    _FooterLink('Sign in', () => context.go('/signin')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FooterLink extends StatefulWidget {
  const _FooterLink(this.label, this.onTap);

  final String label;
  final VoidCallback onTap;

  @override
  State<_FooterLink> createState() => _FooterLinkState();
}

class _FooterLinkState extends State<_FooterLink> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: widget.label,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          // Semantics are declared by the Semantics wrapper above this
          // control; without this the detector emits a second, unlabelled
          // tappable node beside it.
          excludeFromSemantics: true,
          onTap: widget.onTap,
          child: ExcludeSemantics(
            child: Text(
              widget.label,
              style: AppTheme.caption.copyWith(
                color: T.signalBlue,
                // The focus indicator here is an underline: these links sit in
                // a Wrap, so a ring would be the only thing marking them and an
                // underline also survives being viewed without colour.
                decoration: _focused ? TextDecoration.underline : null,
                decorationColor: T.signalBlue,
                decorationThickness: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
