import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/auth_service.dart';
import '../services/case_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'pill_button.dart';

/// Sticky top nav: 6px-radius logo container, centered links, black pill CTA
/// on the right.
class SiteNav extends StatelessWidget {
  const SiteNav({super.key, this.transparent = true, this.activeRoute});

  final bool transparent;
  final String? activeRoute;

  @override
  Widget build(BuildContext context) {
    final compact = Breaks.isMobile(context);
    return AnimatedBuilder(
      animation: AuthService.instance,
      builder: (context, _) {
        final auth = AuthService.instance;
        return Container(
          decoration: BoxDecoration(
            color: T.paper.withValues(alpha: transparent ? 0.88 : 1),
            border: const Border(bottom: BorderSide(color: Color(0x228C9BAA))),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? T.s16 : T.s32,
            vertical: 14,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: T.pageMaxWidth),
              // The nav is the site's primary navigation landmark; naming it
              // lets a screen reader jump to (and past) it as one block.
              child: Semantics(
                explicitChildNodes: true,
                label: 'Main navigation',
                child: Row(
                  children: [
                    const _Wordmark(),
                    const Spacer(),
                    if (!compact) ...[
                      if (auth.isSignedIn)
                        _NavLink(
                          label: 'My pathway',
                          active: activeRoute == '/dashboard',
                          onTap: () => context.go('/dashboard'),
                        ),
                      _NavLink(
                        label: 'Pathways',
                        active: activeRoute == '/visa-pathways',
                        onTap: () => context.go('/visa-pathways'),
                      ),
                      _NavLink(
                        label: 'News',
                        active: activeRoute == '/news',
                        onTap: () => context.go('/news'),
                      ),
                      // Guarded, so it only appears once there is an account
                      // to hang the self-assessment off.
                      if (auth.isSignedIn)
                        _NavLink(
                          label: 'O-1 / EB-1',
                          active: activeRoute?.startsWith('/evidence') ?? false,
                          onTap: () => context.go('/evidence'),
                        ),
                      _NavLink(
                        label: 'What it does',
                        onTap: () => _scrollHome(context, 'how'),
                      ),
                      const Spacer(),
                    ],
                    if (auth.isSignedIn) ...[
                      if (!compact)
                        _AccountChip(session: auth.session!)
                      else
                        PillButton(
                          label: 'My pathway',
                          variant: PillVariant.ink,
                          trailingIcon: Icons.arrow_forward,
                          onPressed: () => context.go('/dashboard'),
                        ),
                    ] else ...[
                      if (!compact) ...[
                        PillButton(
                          label: 'Log in',
                          onPressed: () => context.go('/signin'),
                        ),
                        const SizedBox(width: T.s8),
                      ],
                      PillButton(
                        label: 'Get started',
                        variant: PillVariant.ink,
                        trailingIcon: Icons.arrow_forward,
                        onPressed: () => context.go('/signin'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _scrollHome(BuildContext context, String anchor) {
    if (GoRouterState.of(context).uri.path != '/') {
      context.go('/');
      return;
    }
    LandingScrollBus.instance.jumpTo(anchor);
  }
}

/// Lets the nav scroll the landing page without threading keys through routes.
class LandingScrollBus {
  LandingScrollBus._();
  static final instance = LandingScrollBus._();

  final Map<String, GlobalKey> anchors = {};

  void jumpTo(String anchor) {
    final key = anchors[anchor]?.currentContext;
    if (key == null) return;
    Scrollable.ensureVisible(
      key,
      duration: const Duration(milliseconds: 620),
      curve: Curves.easeInOutCubic,
      alignment: 0.02,
    );
  }
}

class _Wordmark extends StatefulWidget {
  const _Wordmark();

  @override
  State<_Wordmark> createState() => _WordmarkState();
}

class _WordmarkState extends State<_Wordmark> {
  bool _focused = false;

  void _go() => context.go('/');

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Lumos, go to the home page',
      onTap: _go,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _go();
              return null;
            },
          ),
        },
        child: GestureDetector(
          // Semantics are declared by the Semantics wrapper above this
          // control; without this the detector emits a second, unlabelled
          // tappable node beside it.
          excludeFromSemantics: true,
          onTap: _go,
          child: ExcludeSemantics(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(T.rNav),
                boxShadow: _focused ? focusRing() : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: T.ink,
                      borderRadius: BorderRadius.circular(T.rNav),
                    ),
                    child: const Icon(
                      Icons.auto_awesome,
                      size: 16,
                      color: T.paper,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Lumos',
                    style: AppTheme.label.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: T.ink,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavLink extends StatefulWidget {
  const _NavLink({
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  State<_NavLink> createState() => _NavLinkState();
}

class _NavLinkState extends State<_NavLink> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      // `selected` is how a screen reader announces "you are already here" for
      // the current page's link.
      selected: widget.active,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
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
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: T.s8,
              ),
              // The ring is a shadow, not a border: a border would reserve
              // width whether or not it is showing and shift the whole nav.
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(T.rNav),
                boxShadow: _focused ? focusRing() : null,
              ),
              child: Text(
                widget.label,
                style: AppTheme.label.copyWith(
                  color: widget.active || _hover ? T.ink : T.graphite,
                  fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Neutral signed-in marker. Lumos holds no user-entered name, so the chip
/// shows an avatar only — the Google account behind it lives in the tooltip.
/// Tapping it opens the account menu: sign out, or switch to a different
/// Google account.
class _AccountChip extends StatelessWidget {
  const _AccountChip({required this.session});

  final UserSession session;

  Future<void> _signOut(BuildContext context, {String destination = '/'}) async {
    // The case is per-account and stays on disk; drop it from memory so the
    // next sign-in starts from its own.
    CaseService.instance.forget();
    await AuthService.instance.signOut();
    if (context.mounted) context.go(destination);
  }

  @override
  Widget build(BuildContext context) {
    final detail =
        'Signed in as ${session.email}. Session valid until '
        '${session.expiresAt.toIso8601String().split('T').first}'
        '${session.isDemo ? '. Demo session' : ''}';

    // Without a label this is a bare decorative circle to a screen reader —
    // the account it stands for lives only here.
    return Semantics(
      label: '$detail. Opens account menu.',
      button: true,
      child: PopupMenuButton<String>(
        tooltip: '',
        padding: EdgeInsets.zero,
        offset: const Offset(0, 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rInput),
        ),
        onSelected: (value) {
          if (value == 'sign_out') _signOut(context);
          if (value == 'switch_account') {
            _signOut(context, destination: '/signin');
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            enabled: false,
            child: Text(session.email, style: AppTheme.caption),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'switch_account',
            child: Row(
              children: [
                Icon(Icons.switch_account_outlined, size: 18),
                SizedBox(width: T.s8),
                Text('Switch account'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'sign_out',
            child: Row(
              children: [
                Icon(Icons.logout, size: 18),
                SizedBox(width: T.s8),
                Text('Sign out'),
              ],
            ),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            border: Border.fromBorderSide(T.hairline),
            borderRadius: BorderRadius.circular(T.rPill),
          ),
          child: Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: T.pastelLavender,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.person_outline, size: 14, color: T.ink),
          ),
        ),
      ),
    );
  }
}
