import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/case_profile.dart';
import '../models/deadline.dart';
import '../models/onboarding_profile.dart';
import '../models/pathway_graph.dart';
import 'auth_service.dart';

/// Works out what this person's dates actually are, and remembers what they did
/// about them.
///
/// **Everything here stays in the browser.** Nothing is posted anywhere: the
/// product's public promise is that it collects no personal data, and a
/// deadline list is a near-complete picture of somebody's immigration status.
/// Storage is `SharedPreferences`, keyed per signed-in user exactly like
/// `CaseService`, so two accounts on one machine never see each other's dates.
///
/// ## What it derives, and from what
///
/// Two inputs, both already in the app:
///
///  * `AuthService.instance.session?.onboarding.situation` — a free-text status,
///    a change date that is at best a month and a year (and is often absent or
///    explicitly unknown), and a free-text goal.
///  * `CaseService.instance.profile` plus the generic pathway graph — the
///    confirmed status node and goal node.
///
/// ## The accuracy rule
///
/// Every derived number is either taken from the pathway JSON's own
/// `recurring_deadlines` wording or is a lead-time heuristic phrased as one
/// ("most people start about six months before"). Where the data does not
/// support a number — grace-period lengths, for instance, which the graph
/// mentions but does not quantify — this emits an **undated** item saying so
/// rather than inventing one. Onboarding never captures a *day*, so every date
/// derived from it is marked [Deadline.isApproximate] and reads as a window.
class DeadlineService extends ChangeNotifier {
  DeadlineService._();
  static final instance = DeadlineService._();

  static const _keyPrefix = 'lumos.deadlines';

  /// The lead time the "start preparing" milestone uses. A heuristic, phrased as
  /// one everywhere it is shown — not a legal deadline.
  static const prepareLeadMonths = 6;

  final List<Deadline> _added = [];
  final Set<String> _dismissed = {};
  final Map<String, DateTime> _snoozed = {};

  bool _loaded = false;
  bool get isLoaded => _loaded;

  List<Deadline> get userAdded => List.unmodifiable(_added);
  Set<String> get dismissedIds => Set.unmodifiable(_dismissed);
  Map<String, DateTime> get snoozedUntil => Map.unmodifiable(_snoozed);

  String get _storageKey {
    final id = AuthService.instance.session?.userId ?? '';
    return id.isEmpty ? _keyPrefix : '$_keyPrefix.$id';
  }

  // ── Storage ───────────────────────────────────────────────────────────────

  /// Safe to call repeatedly; reads once per signed-in user.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null) {
        _adopt(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      // Corrupt or unavailable storage means "nothing added, nothing
      // dismissed" — the derived list still works, which is the important half.
    }
    notifyListeners();
  }

  void _adopt(Map<String, dynamic> j) {
    _added
      ..clear()
      ..addAll([
        for (final d in (j['added'] as List? ?? const []))
          Deadline.fromJson((d as Map).cast<String, dynamic>()),
      ]);
    _dismissed
      ..clear()
      ..addAll([
        for (final id in (j['dismissed'] as List? ?? const [])) id as String,
      ]);
    _snoozed.clear();
    for (final entry in (j['snoozed'] as Map? ?? const {}).entries) {
      final until = DateTime.tryParse('${entry.value}');
      if (until != null) _snoozed['${entry.key}'] = until;
    }
  }

  Map<String, dynamic> toJson() => {
    'added': [for (final d in _added) d.toJson()],
    'dismissed': _dismissed.toList(),
    'snoozed': {
      for (final e in _snoozed.entries) e.key: e.value.toIso8601String(),
    },
  };

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(toJson()));
    } catch (_) {
      // In-memory for this session is still usable.
    }
  }

  /// Drops in-memory state on sign-out. The stored copy stays on disk, keyed to
  /// that user, so signing back in restores it.
  void forget() {
    _added.clear();
    _dismissed.clear();
    _snoozed.clear();
    _loaded = false;
    notifyListeners();
  }

  // ── Mutations ─────────────────────────────────────────────────────────────

  Future<void> add(Deadline deadline) async {
    _added
      ..removeWhere((d) => d.id == deadline.id)
      ..add(deadline);
    notifyListeners();
    await _persist();
  }

  /// Builds a user deadline with a fresh id. [now] is injected so tests get a
  /// deterministic id and the model stays clock-free.
  static Deadline compose({
    required String title,
    required DateTime now,
    String description = '',
    DateTime? dueDate,
    bool isApproximate = false,
    String nextAction = '',
  }) {
    final approximate = dueDate != null && isApproximate;
    return Deadline(
      id: 'user.${now.microsecondsSinceEpoch}',
      title: title.trim(),
      description: description.trim(),
      dueDate: dueDate,
      isApproximate: approximate,
      approximateLabel: approximate
          ? '${Deadline.monthName(dueDate.month)} ${dueDate.year}'
          : null,
      severity: DeadlineSeverity.important,
      source: DeadlineSource.userAdded,
      nextAction: nextAction.trim(),
    );
  }

  /// Removes a user-added item outright. Derived items cannot be removed, only
  /// dismissed — they would come straight back on the next derivation.
  Future<void> remove(String id) async {
    _added.removeWhere((d) => d.id == id);
    _dismissed.remove(id);
    _snoozed.remove(id);
    notifyListeners();
    await _persist();
  }

  Future<void> dismiss(String id) async {
    _dismissed.add(id);
    _snoozed.remove(id);
    notifyListeners();
    await _persist();
  }

  /// Undo, from the "hidden" list. Nothing is ever destroyed by a dismissal.
  Future<void> restore(String id) async {
    _dismissed.remove(id);
    _snoozed.remove(id);
    notifyListeners();
    await _persist();
  }

  /// Hides an item until [until]. Snoozing is the gentler default: it says "not
  /// now" without asking somebody to decide that a date does not matter.
  Future<void> snooze(String id, DateTime until) async {
    _snoozed[id] = DateTime(until.year, until.month, until.day);
    notifyListeners();
    await _persist();
  }

  bool isHidden(String id, DateTime now) {
    if (_dismissed.contains(id)) return true;
    final until = _snoozed[id];
    if (until == null) return false;
    return DateTime(now.year, now.month, now.day).isBefore(until);
  }

  // ── Reads ─────────────────────────────────────────────────────────────────

  /// The full list, sorted, with dismissed and snoozed items removed.
  List<Deadline> visible({
    VisaSituation? situation,
    CaseProfile? profile,
    PathwayGraph? graph,
    required DateTime now,
  }) {
    final all = <Deadline>[
      ...derive(situation: situation, profile: profile, graph: graph, now: now),
      ..._added,
    ]..removeWhere((d) => isHidden(d.id, now));
    return Deadline.sorted(all, now);
  }

  /// Everything currently hidden, so the UI can offer it back.
  List<Deadline> hidden({
    VisaSituation? situation,
    CaseProfile? profile,
    PathwayGraph? graph,
    required DateTime now,
  }) {
    final all = <Deadline>[
      ...derive(situation: situation, profile: profile, graph: graph, now: now),
      ..._added,
    ].where((d) => isHidden(d.id, now));
    return Deadline.sorted(all, now);
  }

  // ── Derivation ────────────────────────────────────────────────────────────

  /// Pure: same inputs, same output. No clock, no storage, no network.
  static List<Deadline> derive({
    VisaSituation? situation,
    CaseProfile? profile,
    PathwayGraph? graph,
    required DateTime now,
  }) {
    final out = <Deadline>[];

    final nodeId = profile?.currentNodeId;
    final node = nodeId == null ? null : graph?.node(nodeId);
    final statusName = node?.name ?? _statusPhrase(situation);

    // ── The anchor: when their status changes ───────────────────────────────
    //
    // Onboarding only ever captures a month and a year (often only a year), so
    // this is always approximate. The anchor is the *first* day of the window:
    // for a deadline, early is the safe direction to be wrong in.
    final expiry = _expiryAnchor(situation);

    if (expiry != null) {
      out.add(
        Deadline(
          id: 'derived.status_expiry',
          title: 'Your current status runs out',
          description:
              'You told me your situation changes ${expiry.label}. Everything '
              'else on this list is measured from this date, so it is the one '
              'worth getting exactly right.',
          dueDate: expiry.date,
          isApproximate: true,
          approximateLabel: expiry.label,
          severity: DeadlineSeverity.critical,
          source: DeadlineSource.derivedFromStatus,
          relatedNodeId: nodeId,
          // The anchor for the whole list. Losing it to a stray tap would
          // quietly break the tracker, so this one is corrected, not dismissed.
          dismissible: false,
          consequence:
              'Staying past the date on your I-94 without a pending or approved '
              'extension generally means falling out of status, which can make '
              'later applications harder.',
          nextAction:
              'Check the exact date on your I-94 or your I-797 approval notice, '
              'and update it here if it is different.',
        ),
      );

      // "Start preparing" — a heuristic, and labelled as one.
      final lead = DateTime(
        expiry.date.year,
        expiry.date.month - prepareLeadMonths,
        expiry.date.day,
      );
      if (lead.isAfter(now)) {
        out.add(
          Deadline(
            id: 'derived.prepare_lead_time',
            title: 'A good time to start your next step',
            description:
                'Not a legal deadline — a head start. People typically begin '
                'the next application around $prepareLeadMonths months before '
                'their status ends, because paperwork, employer sign-off and '
                'processing times all take longer than they look.',
            dueDate: lead,
            isApproximate: true,
            approximateLabel: '${Deadline.monthName(lead.month)} ${lead.year}',
            severity: DeadlineSeverity.important,
            source: DeadlineSource.derivedFromStatus,
            relatedNodeId: nodeId,
            consequence:
                'Nothing happens on this date. Leaving it much later is simply '
                'where most of the stress comes from.',
            nextAction:
                'Pick one thing — talk to your DSO, your employer, or a lawyer '
                'about what comes after ${statusName ?? 'your current status'}.',
          ),
        );
      }

      // Grace periods: the graph mentions them but does not quantify them, so
      // this is undated on purpose rather than asserting "60 days".
      out.add(
        const Deadline(
          id: 'derived.grace_period_check',
          title: 'Find out how long your grace period is',
          description:
              'Most statuses come with a short period after they end in which '
              'you can leave, change status, or have a new filing pending. How '
              'long it is depends on your status, and it is not automatic in '
              'every case — so it is worth knowing your number before you need '
              'it.',
          isApproximate: false,
          severity: DeadlineSeverity.important,
          source: DeadlineSource.derivedFromStatus,
          consequence:
              'Assuming a grace period you do not have is one of the commonest '
              'ways people accidentally overstay.',
          nextAction:
              'Ask your DSO, your immigration lawyer, or check the USCIS page '
              'for your specific status.',
        ),
      );
    } else if (situation != null && situation.hasStatus) {
      // They have a status but no usable date — including the explicit "I don't
      // know". That is a real, trackable task, not an empty list.
      out.add(
        Deadline(
          id: 'derived.expiry_unknown',
          title: 'Find out when your status actually ends',
          description: situation.dateUnknown
              ? 'You said you are not sure when your situation changes, which is '
                    'completely normal — the date is not printed anywhere '
                    'obvious. Once you have it, everything else here can be '
                    'worked out from it.'
              : 'I do not have a date for when your current status ends yet. It '
                    'is the one fact the rest of this list is built on.',
          severity: DeadlineSeverity.critical,
          source: DeadlineSource.derivedFromStatus,
          relatedNodeId: nodeId,
          dismissible: false,
          consequence:
              'Without it, nothing here can warn you in advance — and the date '
              'on your visa stamp is usually not the one that counts.',
          nextAction:
              'Look up your most recent I-94 at i94.cbp.dhs.gov — the '
              '"admit until" date there is the one that governs your stay.',
        ),
      );
    }

    // The I-94 / visa-stamp distinction. Undated, and one of the highest-value
    // things this product can tell somebody.
    if (situation != null && (situation.hasStatus || situation.hasDate)) {
      out.add(
        const Deadline(
          id: 'derived.i94_vs_visa',
          title: 'Your visa sticker and your I-94 are two different dates',
          description:
              'The visa in your passport is generally just permission to travel '
              'to a US border, and its date is about when you can arrive. How '
              'long you may actually stay is the "admit until" date on your '
              'I-94. They often do not match, and it is the I-94 that counts.',
          severity: DeadlineSeverity.routine,
          source: DeadlineSource.derivedFromStatus,
          consequence:
              'People reading the wrong one is a common way an overstay happens '
              'without anybody noticing at the time.',
          nextAction:
              'Pull your I-94 record at i94.cbp.dhs.gov and compare the two '
              'dates. Keep a copy.',
        ),
      );
    }

    out.addAll(
      _fromPathway(
        situation: situation,
        profile: profile,
        graph: graph,
        node: node,
        expiry: expiry,
        now: now,
      ),
    );

    return Deadline.sorted(out, now);
  }

  /// Pathway-driven items. Each one is gated on the generic pathway graph
  /// actually carrying the relevant `recurring_deadlines` wording, so a change
  /// to that file removes the claim here rather than leaving a stale number.
  static List<Deadline> _fromPathway({
    required VisaSituation? situation,
    required CaseProfile? profile,
    required PathwayGraph? graph,
    required PathwayNode? node,
    required _Anchor? expiry,
    required DateTime now,
  }) {
    if (graph == null) return const [];
    final out = <Deadline>[];
    final currentId = node?.id;

    // ── H-1B cap registration ───────────────────────────────────────────────
    final h1b = graph.node('temp_worker.h1b');
    final registrationLine = _lineContaining(h1b, ['registration']);
    final wantsH1b =
        profile != null &&
        (profile.goalNodeId == 'temp_worker.h1b' ||
            profile.alternativeGoalIds.contains('temp_worker.h1b') ||
            (currentId != null &&
                graph
                    .edgesFrom(currentId)
                    .any((e) => e.to == 'temp_worker.h1b')));

    if (wantsH1b && registrationLine != null && h1b != null) {
      // The window is typically early-to-mid March; once this year's is
      // comfortably past, point at next year's rather than showing an item
      // that is permanently overdue.
      final year = now.isBefore(DateTime(now.year, 3, 15))
          ? now.year
          : now.year + 1;
      out.add(
        Deadline(
          id: 'derived.h1b_registration.$year',
          title: 'H-1B registration window (typically March)',
          description:
              'If an employer is going to enter you in the H-1B lottery, they '
              'register you in a short window that is typically in March, for a '
              'job that generally cannot start before October 1. The pathway '
              'data records it as: "$registrationLine". Your employer does this '
              'part, not you.',
          dueDate: DateTime(year, 3, 1),
          isApproximate: true,
          approximateLabel: 'March $year',
          severity: DeadlineSeverity.critical,
          source: DeadlineSource.derivedFromPathway,
          relatedNodeId: h1b.id,
          consequence:
              'The window is short and there is generally no way in until the '
              'next one, typically a year later.',
          nextAction:
              'Ask your employer now whether they will register you, and '
              'whether they have sponsored H-1B before.',
        ),
      );
    }

    // ── OPT filing window, relative to the program end date ─────────────────
    final opt = graph.node('student.opt_postcompletion');
    final optLine = _lineContaining(opt, ['90 days before']);
    final onF1Track =
        currentId == 'student.f1' || currentId == 'student.opt_precompletion';
    if (onF1Track && optLine != null && expiry != null && opt != null) {
      final opens = expiry.date.subtract(const Duration(days: 90));
      out.add(
        Deadline(
          id: 'derived.opt_window_opens',
          title: 'OPT filing window typically opens',
          description:
              'If the date you gave me is your program end date, this is roughly '
              'when you can generally start filing for post-completion OPT. The '
              'pathway data records the window as: "$optLine". Processing '
              'commonly runs a few months, so people usually file as early as '
              'they are allowed to.',
          dueDate: opens,
          isApproximate: true,
          approximateLabel: '${Deadline.monthName(opens.month)} ${opens.year}',
          severity: DeadlineSeverity.critical,
          source: DeadlineSource.derivedFromPathway,
          relatedNodeId: opt.id,
          consequence:
              'Filing late eats into the time you can actually work, and filing '
              'outside the window can mean it is not accepted at all.',
          nextAction:
              'Ask your DSO to confirm your program end date and the exact first '
              'day you can file.',
        ),
      );
    }

    // ── Conditional green card: the 90-day window before it expires ─────────
    final conditional = graph.node('post_lpr.conditional_gc');
    final conditionalLine = _lineContaining(conditional, ['90-day window']);
    if (currentId == 'post_lpr.conditional_gc' &&
        conditionalLine != null &&
        expiry != null) {
      final opens = expiry.date.subtract(const Duration(days: 90));
      out.add(
        Deadline(
          id: 'derived.conditional_gc_window',
          title: 'Window to remove the conditions typically opens',
          description:
              'A two-year conditional card is normally followed by a filing to '
              'remove the conditions. The pathway data records it as: '
              '"$conditionalLine".',
          dueDate: opens,
          isApproximate: true,
          approximateLabel: '${Deadline.monthName(opens.month)} ${opens.year}',
          severity: DeadlineSeverity.critical,
          source: DeadlineSource.derivedFromPathway,
          relatedNodeId: conditional!.id,
          consequence:
              'Missing the window can put permanent-resident status itself at '
              'risk, so it is one to diarise properly.',
          nextAction:
              'Check the expiry date printed on your card and confirm the filing '
              'window with a lawyer.',
        ),
      );
    }

    // ── Ongoing obligations for the current status ─────────────────────────
    //
    // Folded into one undated item rather than five: five separate cards for
    // things with no date is exactly the noise this screen exists to avoid.
    if (node != null && node.recurringDeadlines.isNotEmpty) {
      final items = node.recurringDeadlines.take(4).toList();
      out.add(
        Deadline(
          id: 'derived.recurring.${node.id}',
          title:
              'Ongoing things to stay on top of while you are on ${node.name}',
          description:
              'These come around on their own schedule rather than on a single '
              'date, and they are quoted from the pathway data as-is:\n'
              '${items.map((i) => '• $i').join('\n')}',
          severity: DeadlineSeverity.routine,
          source: DeadlineSource.derivedFromPathway,
          relatedNodeId: node.id,
          consequence:
              'These are the requirements that keep your current status valid '
              'day to day.',
          nextAction:
              'Read through them once and note which apply to you — most people '
              'find one or two they did not know about.',
        ),
      );
    }

    return out;
  }

  /// The first `recurring_deadlines` line on [node] containing every needle.
  /// Null when the data does not say it — which is the signal not to claim it.
  static String? _lineContaining(PathwayNode? node, List<String> needles) {
    if (node == null) return null;
    for (final line in node.recurringDeadlines) {
      final lower = line.toLowerCase();
      if (needles.every((n) => lower.contains(n.toLowerCase()))) return line;
    }
    return null;
  }

  /// The change date from onboarding, as an anchor plus the words to say it in.
  /// Null when there is no year, or when the person said outright they do not
  /// know — "I don't know" must never become a date.
  static _Anchor? _expiryAnchor(VisaSituation? s) {
    if (s == null || s.dateUnknown) return null;
    final year = s.changeYear;
    if (year == null) return null;
    final month = s.changeMonth;
    if (month != null && month >= 1 && month <= 12) {
      return _Anchor(
        DateTime(year, month, 1),
        '${Deadline.monthName(month)} $year',
      );
    }
    return _Anchor(DateTime(year, 1, 1), '$year');
  }

  static String? _statusPhrase(VisaSituation? s) {
    final chip = s?.statusChip?.trim();
    if (chip != null && chip.isNotEmpty) return chip;
    return null;
  }
}

/// An approximate date plus how to say it out loud.
@immutable
class _Anchor {
  const _Anchor(this.date, this.label);
  final DateTime date;
  final String label;
}
