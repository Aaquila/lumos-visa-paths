import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/google_sign_in_button.dart';
import '../../widgets/hero_journey.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/site_footer.dart';
import '../../widgets/site_nav.dart';

/// Google sign-in only (PROJECT_PRD §5) — no password flow to build, and one
/// fewer credential for someone already juggling case numbers.
///
/// The sign-in itself is real Google Identity Services; see [AuthService] for
/// how the ID token becomes a 14-day application session, and what happens when
/// the build has no OAuth client id configured.
class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _auth = AuthService.instance;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// Sign-in can complete without a button press of ours — on the web the GIS
  /// button drives it — so navigation hangs off the auth state, not a callback.
  void _onAuthChanged() {
    if (!mounted) return;
    if (_auth.isSignedIn) {
      context.go('/dashboard');
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    return Scaffold(
      backgroundColor: T.paper,
      body: Column(
        children: [
          const SiteNav(activeRoute: '/signin'),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: mobile ? T.s24 : T.s32,
                      vertical: mobile ? T.s40 : T.s56,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: T.pageMaxWidth,
                        ),
                        child: Flex(
                          direction: mobile ? Axis.vertical : Axis.horizontal,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (mobile)
                              const _Pitch()
                            else
                              const Expanded(flex: 5, child: _Pitch()),
                            const SizedBox(width: T.s72, height: T.s40),
                            if (mobile)
                              const _Card()
                            else
                              const Expanded(flex: 5, child: _Card()),
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
      ),
    );
  }
}

class _Pitch extends StatelessWidget {
  const _Pitch();

  @override
  Widget build(BuildContext context) {
    const points = [
      (
        Icons.lock_outline,
        'Your case data is yours',
        'Every record is scoped to your account — nothing shared, nothing '
            'used to answer anyone else\'s question.',
        T.pastelMint,
      ),
      (
        Icons.schedule,
        'Signed in for two weeks',
        'Long enough to avoid a deadline-scramble login, short enough to '
            'matter on a shared laptop.',
        T.pastelLavender,
      ),
      (
        Icons.delete_outline,
        'Leave whenever',
        'Delete your account and the case facts, deadlines and chat history go '
            'with it.',
        T.pastelPeach,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StepBadge(step: 'Step 0', descriptor: 'sign in'),
        const SizedBox(height: T.s24),
        Text(
          'Sign in to see your\npersonal pathway.',
          style: AppTheme.headingLg(context),
        ),
        const SizedBox(height: T.s16),
        Text(
          'The generic map is open to everyone. Signing in puts you on it '
          '— and keeps the deadlines that follow.',
          style: AppTheme.body,
        ),
        const SizedBox(height: T.s40),
        for (final (icon, title, body, accent) in points)
          Padding(
            padding: const EdgeInsets.only(bottom: T.s24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PastelIconBadge(icon: icon, fill: accent, size: 30),
                const SizedBox(width: T.s16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTheme.bodySm.copyWith(
                          color: T.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(body, style: AppTheme.bodySm),
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

class _Card extends StatefulWidget {
  const _Card();

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  /// Off by default: the device may be shared (Frontend UI PRD §3.1).
  bool _staySignedIn = false;

  @override
  void initState() {
    super.initState();
    AuthService.instance.staySignedIn = _staySignedIn;
  }

  void _setStay(bool value) {
    setState(() => _staySignedIn = value);
    // Recorded before the Google flow starts, since the flow returns through a
    // stream rather than through us.
    AuthService.instance.staySignedIn = value;
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;

    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) => Container(
        padding: const EdgeInsets.all(T.s32),
        decoration: BoxDecoration(
          color: T.paper,
          border: Border.fromBorderSide(T.hairline),
          borderRadius: BorderRadius.circular(T.rFeatureCard),
          boxShadow: T.floatShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A short version of the hero journey, so the sign-in screen still
            // feels like the same product.
            const SizedBox(
              height: 150,
              child: HeroJourney(
                height: 150,
                stops: [
                  JourneyStop(
                    label: 'Sign in',
                    caption: 'Google',
                    icon: Icons.login,
                  ),
                  JourneyStop(
                    label: 'Your situation',
                    caption: 'in your words',
                    icon: Icons.chat_bubble_outline,
                  ),
                  JourneyStop(
                    label: 'Your map',
                    caption: 'ready',
                    icon: Icons.map_outlined,
                    isDestination: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: T.s24),
            Text('Welcome to Lumos', style: AppTheme.headingSm),
            const SizedBox(height: 6),
            Text(
              'One account, one map, every deadline it implies.',
              style: AppTheme.bodySm,
            ),
            const SizedBox(height: T.s24),

            if (auth.isConfigured)
              const GoogleSignInButton(width: 320)
            else
              const _NotConfiguredNotice(),

            const SizedBox(height: T.s16),
            InkWell(
              borderRadius: BorderRadius.circular(T.rInput),
              onTap: () => _setStay(!_staySignedIn),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: Checkbox(
                        value: _staySignedIn,
                        onChanged: (v) => _setStay(v ?? false),
                        activeColor: T.signalBlue,
                        side: const BorderSide(color: T.pencilGray),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Stay signed in on this device for 14 days',
                        style: AppTheme.bodySm,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (auth.error != null) ...[
              const SizedBox(height: T.s16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: T.signalBlue),
                  borderRadius: BorderRadius.circular(T.rInput),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 16,
                      color: T.signalBlue,
                    ),
                    const SizedBox(width: T.s8),
                    Expanded(
                      child: Text(
                        auth.error!,
                        style: AppTheme.bodySm.copyWith(color: T.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: T.s24),
            const Divider(),
            const SizedBox(height: T.s16),
            Text(
              'Not ready to sign in?',
              style: AppTheme.bodySm.copyWith(color: T.ink),
            ),
            const SizedBox(height: T.s8),
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                PillButton(
                  label: 'Browse the generic pathways map',
                  icon: Icons.account_tree_outlined,
                  onPressed: () => context.go('/visa-pathways'),
                ),
                if (!auth.isConfigured)
                  PillButton(
                    label: 'Continue as a demo user',
                    icon: Icons.science_outlined,
                    onPressed: () =>
                        auth.continueAsDemoUser(rememberMe: _staySignedIn),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the build carries no OAuth client id. Being explicit beats a
/// button that looks real and silently signs nobody in.
class _NotConfiguredNotice extends StatelessWidget {
  const _NotConfiguredNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const PastelIconBadge(
                icon: Icons.key_outlined,
                fill: T.pastelYellow,
                size: 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Google sign-in is not configured for this build',
                  style: AppTheme.bodySm.copyWith(
                    color: T.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: T.s8),
          Text(
            'Add GOOGLE_AUTH_CLIENT_ID=<your-client-id> to the root .env file, '
            'then start the app with:',
            style: AppTheme.bodySm,
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7F9),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              './scripts/run_web.ps1',
              style: AppTheme.caption.copyWith(
                fontFamily: 'monospace',
                color: T.carbon,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text('Full walkthrough: docs/RUNNING.md', style: AppTheme.caption),
        ],
      ),
    );
  }
}
