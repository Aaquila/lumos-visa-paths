import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/onboarding_profile.dart';
import '../../services/auth_service.dart';
import '../../services/situation_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/quick_pick_chip.dart';
import '../../widgets/voice_input_button.dart';
import 'onboarding_scaffold.dart';

/// Onboarding step 2: the visa situation, asked one question at a time.
///
/// Three questions — what you're on, when it changes, what you want — each on
/// its own screen. Free text is the primary input for the two that matter:
/// people describe their status the way they live it, and a dropdown of visa
/// codes turns "my OPT started in June" into a quiz. The chips are shortcuts
/// for people who already know the label, and the text box never goes away.
///
/// Every question can be skipped and the whole step can be left; the date is
/// forgiving down to "I don't know".
class SituationPage extends StatefulWidget {
  const SituationPage({super.key});

  @override
  State<SituationPage> createState() => _SituationPageState();
}

class _SituationPageState extends State<SituationPage> {
  static const _questionCount = 3;

  late final VisaSituation _initial =
      AuthService.instance.onboarding.situation ?? const VisaSituation();

  late final _status = TextEditingController(text: _initial.statusText);
  late final _goal = TextEditingController(text: _initial.goalText);

  late String? _statusChip = _initial.statusChip;
  late String? _goalChip = _initial.goalChip;
  late int? _year = _initial.changeYear;
  late int? _month = _initial.changeMonth;
  late bool _dateUnknown = _initial.dateUnknown;

  int _question = 0;

  @override
  void dispose() {
    _status.dispose();
    _goal.dispose();
    super.dispose();
  }

  VisaSituation get _current => VisaSituation(
    statusText: _status.text,
    statusChip: _statusChip,
    changeYear: _dateUnknown ? null : _year,
    changeMonth: _dateUnknown ? null : _month,
    dateUnknown: _dateUnknown,
    goalText: _goal.text,
    goalChip: _goalChip,
  );

  void _next() {
    if (_question < _questionCount - 1) {
      // A draft, not an answer: the step is not done until they say it is.
      unawaited(AuthService.instance.saveSituationDraft(_current));
      setState(() => _question++);
      return;
    }
    _finish();
  }

  void _back() {
    if (_question == 0) {
      context.go('/onboarding/name');
      return;
    }
    unawaited(AuthService.instance.saveSituationDraft(_current));
    setState(() => _question--);
  }

  Future<void> _finish() async {
    await AuthService.instance.saveSituation(_current);
    // Best-effort mirror to the backend — this is what personalized news
    // scores against. Never blocks navigation: the local save above already
    // succeeded, and a signed-out/demo/offline caller just keeps the public
    // feed, same as everywhere else the backend is optional.
    unawaited(SituationService.instance.save(_current));
    if (!mounted) return;
    context.go('/dashboard');
  }

  Future<void> _skipEverything() async {
    await AuthService.instance.skipSituation();
    if (!mounted) return;
    context.go('/dashboard');
  }

  @override
  Widget build(BuildContext context) {
    final (String title, String subtitle, Widget body) = switch (_question) {
      0 => (
        'What\'s your situation right now?',
        'However you\'d say it out loud — there\'s no right way to put it, and '
            'you don\'t need the paperwork in front of you.',
        _statusQuestion(),
      ),
      1 => (
        'When does it change or run out?',
        'Roughly is fine. A month and year, just a year, or "I don\'t know" '
            '— none of it blocks anything.',
        _dateQuestion(),
      ),
      _ => (
        'What would you like to happen?',
        'Where you\'d like this to go — a direction is plenty, no plan '
            'needed.',
        _goalQuestion(),
      ),
    };

    final last = _question == _questionCount - 1;

    return OnboardingScaffold(
      step: 2,
      totalSteps: 2,
      progressNote: 'question ${_question + 1} of $_questionCount',
      title: title,
      subtitle: subtitle,
      onBack: _back,
      footer: Wrap(
        spacing: T.s8,
        runSpacing: T.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PillButton(
            label: last ? 'Done' : 'Next',
            variant: PillVariant.signal,
            trailingIcon: Icons.arrow_forward,
            large: true,
            onPressed: _next,
          ),
          PillButton(
            label: last ? 'Skip and finish' : 'Skip this one',
            onPressed: last
                ? _skipEverything
                : () => setState(() => _question++),
          ),
          if (!last)
            PillButton(label: 'Skip all', onPressed: _skipEverything),
        ],
      ),
      child: body,
    );
  }

  // ── Questions ─────────────────────────────────────────────────────────────

  Widget _statusQuestion() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _BigField(
        controller: _status,
        hint: 'I\'m on a student visa, my OPT started in June.',
        voiceLabel: 'your situation right now',
        maxLines: 5,
      ),
      const SizedBox(height: T.s24),
      _ChipRow(
        caption: 'Or tap one if it\'s quicker. Optional.',
        labels: VisaSituation.statusChips,
        selected: _statusChip,
        onSelect: (label) =>
            setState(() => _statusChip = _statusChip == label ? null : label),
      ),
    ],
  );

  Widget _dateQuestion() {
    final thisYear = DateTime.now().year;
    final years = [for (var y = thisYear; y <= thisYear + 5; y++) y];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Year', style: AppTheme.label),
        const SizedBox(height: T.s8),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            for (final year in years)
              QuickPickChip(
                label: '$year',
                selected: !_dateUnknown && _year == year,
                onTap: () => setState(() {
                  _dateUnknown = false;
                  _year = _year == year ? null : year;
                }),
              ),
            QuickPickChip(
              label: 'Before $thisYear',
              selected: !_dateUnknown && _year != null && _year! < thisYear,
              onTap: () => setState(() {
                _dateUnknown = false;
                _year = _year != null && _year! < thisYear
                    ? null
                    : thisYear - 1;
              }),
            ),
            QuickPickChip(
              label: 'I don\'t know',
              selected: _dateUnknown,
              onTap: () => setState(() {
                _dateUnknown = !_dateUnknown;
                if (_dateUnknown) {
                  _year = null;
                  _month = null;
                }
              }),
            ),
          ],
        ),
        const SizedBox(height: T.s24),
        Text('Month, if you know it', style: AppTheme.label),
        const SizedBox(height: 4),
        Text(
          'The year on its own is a perfectly good answer.',
          style: AppTheme.bodySm,
        ),
        const SizedBox(height: T.s8),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            for (var m = 1; m <= 12; m++)
              QuickPickChip(
                label: VisaSituation.monthNames[m - 1].substring(0, 3),
                selected: !_dateUnknown && _month == m,
                onTap: () => setState(() {
                  _dateUnknown = false;
                  _month = _month == m ? null : m;
                }),
              ),
          ],
        ),
      ],
    );
  }

  Widget _goalQuestion() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _BigField(
        controller: _goal,
        hint: 'I want to work in the US and eventually get a green card.',
        voiceLabel: 'what you\'d like to happen',
        maxLines: 4,
      ),
      const SizedBox(height: T.s24),
      _ChipRow(
        caption: 'Or pick a direction. Optional.',
        labels: VisaSituation.goalChips,
        selected: _goalChip,
        onSelect: (label) =>
            setState(() => _goalChip = _goalChip == label ? null : label),
      ),
    ],
  );
}

// ── Pieces ──────────────────────────────────────────────────────────────────

class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.caption,
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  final String caption;
  final List<String> labels;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption, style: AppTheme.bodySm),
        const SizedBox(height: T.s8),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            for (final label in labels)
              QuickPickChip(
                label: label,
                selected: selected == label,
                onTap: () => onSelect(label),
              ),
          ],
        ),
      ],
    );
  }
}

/// The free-text box, with the option of saying it instead.
///
/// The page already asks for this "however you'd say it out loud", so a
/// microphone is the smaller ask, not the bigger one — for anyone dictating on
/// a phone, writing in a second language, or simply out of energy for typing a
/// paragraph. It sits under the box rather than inside it: the field keeps its
/// full width, and on browsers without speech recognition the row disappears
/// and nothing about the layout admits it was ever there.
class _BigField extends StatelessWidget {
  const _BigField({
    required this.controller,
    required this.hint,
    required this.voiceLabel,
    this.maxLines = 4,
  });

  final TextEditingController controller;
  final String hint;

  /// Plain-language name of this box, for the microphone's screen-reader label.
  final String voiceLabel;

  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Names the box for a screen reader, which the design otherwise leaves
        // to a hint the reader may never reach. Not `textField: true` — the
        // TextField underneath already carries that role, and claiming it twice
        // would announce two boxes where there is one.
        Semantics(
          label: 'In your own words: $voiceLabel',
          hint: 'Type as much or as little as you like. You can skip it.',
          child: TextField(
            controller: controller,
            maxLines: maxLines,
            minLines: maxLines,
            autofocus: false,
            keyboardType: TextInputType.multiline,
            style: AppTheme.inter(18, height: 1.5, color: T.ink),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: AppTheme.inter(18, height: 1.5, color: T.pencilGray),
              filled: true,
              fillColor: T.paper,
              contentPadding: const EdgeInsets.all(T.s24),
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
        ),
        const SizedBox(height: T.s8),
        VoiceInputButton(controller: controller, fieldLabel: voiceLabel),
      ],
    );
  }
}
