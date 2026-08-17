import 'package:flutter/material.dart';

import '../../services/ics_export.dart';
import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/site_footer.dart';
import '../../widgets/site_nav.dart';

/// `/settings/notifications` — what Lumos will and will not tell you.
///
/// Two things make this screen unusual, and both are deliberate.
///
/// **It tells the truth about its own limits.** Lumos runs in a browser tab.
/// The browser cannot wake itself to notify anyone once that tab is closed —
/// that needs Web Push and a server behind it, which this build does not have.
/// Rather than a settings screen that implies otherwise and quietly fails on
/// the one date that mattered, the honesty card below says so in plain English
/// and points at the calendar export, which genuinely does work.
///
/// **Its defaults are deliberately gentle.** The people using this are already
/// frightened of these dates. Reminders lead by 30/7/1 days, never fire more
/// than once a day per deadline, arrive silently, and never say "you missed
/// this". The global mute is the first control on the page, not the last.
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  /// The route this page expects to be mounted at. Registering it belongs to
  /// whoever owns `app/router.dart`.
  static const routePath = '/settings/notifications';

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  NotificationService get _svc => NotificationService.instance;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Idempotent — the app may already have initialised it at start-up.
    _svc.initialize();
  }

  Future<void> _request() async {
    setState(() => _busy = true);
    await _svc.requestPermission();
    if (!mounted) return;
    setState(() => _busy = false);

    final status = _svc.permissionStatus;
    _say(switch (status) {
      NotificationPermission.granted =>
        'Reminders are on. They will appear while Lumos is open.',
      NotificationPermission.denied =>
        'Your browser is blocking notifications. Change that in the padlock '
            'menu next to the address bar.',
      NotificationPermission.unsupported =>
        'This browser does not support notifications. The calendar export '
            'below still works.',
      NotificationPermission.notAsked => 'No change — nothing was decided.',
    });
  }

  Future<void> _test() async {
    final ok = await _svc.showNow(
      title: 'What a Lumos reminder looks like',
      body: 'Quiet, at most once a day, never about anything already done.',
      id: 'lumos.test',
    );
    if (!mounted) return;
    _say(
      ok
          ? 'Sent. If nothing appeared, check focus or do-not-disturb mode.'
          : 'Nothing was sent — reminders are either muted or not permitted '
                'yet.',
    );
  }

  Future<void> _export() async {
    final reminders = _svc.listScheduled();
    if (reminders.isEmpty) {
      _say(
        'Nothing to export yet — once Lumos knows your dates, they will '
        'land here.',
      );
      return;
    }
    final ok = IcsExport.download(reminders);
    if (!mounted) return;
    _say(
      ok
          ? 'Downloaded. Open it and your calendar will offer to add every '
                'date — these reach you even with Lumos closed.'
          : 'The download could not start in this browser.',
    );
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: T.ink,
          content: Text(
            message,
            style: AppTheme.inter(14, color: T.paper, height: 1.4),
          ),
          duration: const Duration(seconds: 6),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    return Scaffold(
      backgroundColor: T.paper,
      body: Column(
        children: [
          const SiteNav(
            transparent: false,
            activeRoute: NotificationSettingsPage.routePath,
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: mobile ? T.s24 : T.s32,
                      vertical: T.s48,
                    ),
                    child: AnimatedBuilder(
                      animation: _svc,
                      builder: (context, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Reminders', style: AppTheme.heading(context)),
                          const SizedBox(height: T.s8),
                          Text(
                            'Lumos tells you about a date before it arrives — '
                            'once, calmly, only about what is still yours to '
                            'do.',
                            style: AppTheme.subheading,
                          ),
                          const SizedBox(height: T.s32),
                          _MuteCard(service: _svc),
                          const SizedBox(height: T.s24),
                          _HonestyCard(service: _svc, onExport: _export),
                          const SizedBox(height: T.s24),
                          _PermissionCard(
                            service: _svc,
                            busy: _busy,
                            onRequest: _request,
                            onTest: _test,
                          ),
                          const SizedBox(height: T.s24),
                          _LeadTimeCard(service: _svc),
                          const SizedBox(height: T.s24),
                          _TypesCard(service: _svc),
                          const SizedBox(height: T.s24),
                          const _PromiseCard(),
                          const SizedBox(height: T.s24),
                          const LegalDisclaimer(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Building blocks ─────────────────────────────────────────────────────────

/// The one card shape used down the page: hairline, generous padding, a title
/// and a supporting line before any control.
class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.children,
    this.blurb,
    this.tint,
  });

  final String title;
  final String? blurb;
  final Color? tint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.cardPadding),
      decoration: BoxDecoration(
        color: tint ?? T.paper,
        border: Border.all(color: const Color(0x448C9BAA)),
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTheme.headingSm),
          if (blurb != null) ...[
            const SizedBox(height: T.s8),
            Text(blurb!, style: AppTheme.body),
          ],
          if (children.isNotEmpty) const SizedBox(height: T.s16),
          ...children,
        ],
      ),
    );
  }
}

/// A switch row with room for a second line, so no toggle is unexplained.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.blurb,
  });

  final String label;
  final String? blurb;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTheme.label),
                if (blurb != null) ...[
                  const SizedBox(height: 2),
                  Text(blurb!, style: AppTheme.bodySm),
                ],
              ],
            ),
          ),
          const SizedBox(width: T.s16),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: T.signalBlue,
            activeThumbColor: T.paper,
          ),
        ],
      ),
    );
  }
}

// ── Cards ───────────────────────────────────────────────────────────────────

/// The global off switch, first on the page and one tap deep.
///
/// Muting is never destructive: the schedule stays, the calendar export still
/// works, and turning it back on restores everything. Somebody switching this
/// off in a bad week should not be quietly deleting their own safety net.
class _MuteCard extends StatelessWidget {
  const _MuteCard({required this.service});

  final NotificationService service;

  @override
  Widget build(BuildContext context) {
    final prefs = service.preferences;
    final snoozed =
        prefs.quietUntil != null && DateTime.now().isBefore(prefs.quietUntil!);

    return _Card(
      title: 'Everything, at once',
      blurb: prefs.muted
          ? 'All reminders are off. Your dates are still saved and '
                'exportable — nothing lost.'
          : 'One switch, if it is all too much today.',
      tint: prefs.muted ? T.pastelYellow.withValues(alpha: 0.35) : null,
      children: [
        _ToggleRow(
          label: 'Mute all reminders',
          blurb: 'Nothing will be shown until you turn this back on.',
          value: prefs.muted,
          onChanged: (v) => service.setMuted(v),
        ),
        if (!prefs.muted) ...[
          const SizedBox(height: T.s8),
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              PillButton(
                label: snoozed ? 'Quiet until later today' : 'Quiet for a day',
                onPressed: () => service.snooze(const Duration(days: 1)),
              ),
              PillButton(
                label: 'Quiet for a week',
                onPressed: () => service.snooze(const Duration(days: 7)),
              ),
              if (snoozed)
                PillButton(
                  label: 'Resume now',
                  variant: PillVariant.outline,
                  onPressed: () => service.updatePreferences(
                    prefs.copyWith(clearQuietUntil: true),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The card that refuses to overpromise.
///
/// Every line here is literally true of this build. If a push backend is ever
/// added, [NotificationService.canDeliverWhenClosed] flips and this card should
/// be revisited in the same change — not before.
class _HonestyCard extends StatelessWidget {
  const _HonestyCard({required this.service, required this.onExport});

  final NotificationService service;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'What actually reaches you',
      blurb:
          'Lumos runs in a browser tab, which cannot wake itself up. Here is '
          'exactly what that means, so nothing about it is a surprise on the '
          'day that counts.',
      tint: T.pastelSky.withValues(alpha: 0.35),
      children: [
        const _FactRow(
          works: true,
          text:
              'Lumos is open in a tab — reminders appear, even on another '
              'tab.',
        ),
        const _FactRow(
          works: false,
          text:
              'Lumos is closed — nothing appears. There is no server here to '
              'push a message to your browser, and we will not pretend '
              'otherwise.',
        ),
        const _FactRow(
          works: true,
          text:
              'You come back later — Lumos catches you up on anything whose '
              'date passed while you were away.',
        ),
        const _FactRow(
          works: true,
          text:
              'You export to your calendar — your phone reminds you whether '
              'or not Lumos is running. This one always works.',
        ),
        const SizedBox(height: T.s16),
        Text(
          'If a date genuinely cannot be missed, put it in your calendar. It '
          'is not a workaround; it is the reliable channel, and it takes one '
          'tap.',
          style: AppTheme.label,
        ),
        const SizedBox(height: T.s16),
        PillButton(
          label: 'Export to my calendar',
          variant: PillVariant.signal,
          icon: Icons.calendar_month_outlined,
          onPressed: onExport,
        ),
        const SizedBox(height: T.s8),
        Text(
          'Downloads a standard .ics file. Google Calendar, Apple Calendar and '
          'Outlook all open it.',
          style: AppTheme.caption,
        ),
      ],
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.works, required this.text});

  final bool works;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: works ? T.pastelMint : T.pastelPink,
              shape: BoxShape.circle,
            ),
            child: Icon(
              works ? Icons.check : Icons.remove,
              size: 13,
              color: T.carbon,
            ),
          ),
          const SizedBox(width: T.s8),
          Expanded(child: Text(text, style: AppTheme.bodySm)),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.service,
    required this.busy,
    required this.onRequest,
    required this.onTest,
  });

  final NotificationService service;
  final bool busy;
  final VoidCallback onRequest;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final status = service.permissionStatus;

    final (String blurb, Widget? action) = switch (status) {
      NotificationPermission.granted => (
        'Your browser is letting Lumos show notifications.',
        PillButton(
          label: 'Send a test reminder',
          icon: Icons.notifications_none,
          onPressed: service.canNotify ? onTest : null,
        ),
      ),
      NotificationPermission.notAsked => (
        'Your browser has not been asked yet. It will show its own prompt — '
            'Lumos only sees yes or no.',
        PillButton(
          label: 'Turn on browser notifications',
          variant: PillVariant.signal,
          busy: busy,
          onPressed: onRequest,
        ),
      ),
      NotificationPermission.denied => (
        'Your browser is blocking notifications for this site. Browsers only '
            'ask once, so Lumos cannot ask again — open the padlock icon next '
            'to the address bar and set Notifications to Allow. The calendar '
            'export still works.',
        null,
      ),
      NotificationPermission.unsupported => (
        'This browser does not support notifications. Nothing else on this '
            'page is affected, and the calendar export still works.',
        null,
      ),
    };

    return _Card(
      title: 'Browser permission',
      blurb: blurb,
      children: [
        ?action,
        if (status == NotificationPermission.granted && !service.canNotify) ...[
          const SizedBox(height: T.s8),
          Text(
            'Permission is granted, but reminders are muted above — nothing '
            'will be shown, including a test.',
            style: AppTheme.caption,
          ),
        ],
      ],
    );
  }
}

/// How much warning the user wants.
///
/// The default set is 30/7/1 days: long enough to gather documents, long enough
/// to book anything that needs booking, and one last quiet note the day before.
/// Nothing fires on the morning of by default — a same-day notification about a
/// filing deadline can only ever be alarming.
class _LeadTimeCard extends StatelessWidget {
  const _LeadTimeCard({required this.service});

  final NotificationService service;

  @override
  Widget build(BuildContext context) {
    final selected = service.preferences.normalised.toSet();

    return _Card(
      title: 'How much warning',
      blurb:
          'Pick as many as help. Lumos still never sends more than one '
          'reminder a day per date, however many you choose.',
      children: [
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            for (final days in NotificationPreferences.leadDayChoices)
              _LeadChip(
                days: days,
                selected: selected.contains(days),
                onChanged: (on) => service.setLeadDay(days, on),
              ),
          ],
        ),
        const SizedBox(height: T.s16),
        Text(
          selected.isEmpty
              ? 'None chosen — Lumos falls back to a single reminder the day '
                    'before, so a date never passes in silence.'
              : 'You will hear from Lumos '
                    '${_humanList(service.preferences.normalised)} before each '
                    'date.',
          style: AppTheme.bodySm,
        ),
      ],
    );
  }

  static String _humanList(List<int> days) {
    final parts = days.map((d) => d == 1 ? '1 day' : '$d days').toList();
    if (parts.length == 1) return parts.first;
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }
}

class _LeadChip extends StatelessWidget {
  const _LeadChip({
    required this.days,
    required this.selected,
    required this.onChanged,
  });

  final int days;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!selected),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? T.signalBlue : T.paper,
          border: Border.all(color: selected ? T.signalBlue : T.pencilGray),
          borderRadius: BorderRadius.circular(T.rPill),
        ),
        child: Text(
          days == 1 ? '1 day before' : '$days days before',
          style: AppTheme.inter(
            14,
            weight: FontWeight.w500,
            color: selected ? T.paper : T.carbon,
          ),
        ),
      ),
    );
  }
}

class _TypesCard extends StatelessWidget {
  const _TypesCard({required this.service});

  final NotificationService service;

  @override
  Widget build(BuildContext context) {
    final prefs = service.preferences;
    return _Card(
      title: 'What to remind me about',
      blurb: 'Switch off anything you would rather track yourself.',
      children: [
        for (final type in ReminderType.values)
          _ToggleRow(
            label: type.label,
            blurb: type.blurb,
            value: prefs.isTypeEnabled(type),
            onChanged: (v) => service.setType(type, v),
          ),
      ],
    );
  }
}

/// The things Lumos will never do. Stated as commitments, because for this
/// audience the absence of a promise reads as a threat.
class _PromiseCard extends StatelessWidget {
  const _PromiseCard();

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'What we will never send you',
      blurb: 'These are not settings. They are commitments.',
      children: const [
        _NeverRow('Never more than one reminder a day per date.'),
        _NeverRow(
          'Never a countdown, a streak, a red badge, or a running tally of '
          'what is outstanding.',
        ),
        _NeverRow(
          'Never marketing, product news, tips, or anything asking you to come '
          'back.',
        ),
        _NeverRow('Never a reminder about something already marked done.'),
        _NeverRow(
          'Never wording that blames you. A passed date is information — '
          'there is almost always a next step.',
        ),
        _NeverRow('Never a sound or a vibration. It waits until you look.'),
      ],
    );
  }
}

class _NeverRow extends StatelessWidget {
  const _NeverRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: T.s8),
            child: SizedBox(
              width: 6,
              height: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: T.pencilGray,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Expanded(child: Text(text, style: AppTheme.bodySm)),
        ],
      ),
    );
  }
}
