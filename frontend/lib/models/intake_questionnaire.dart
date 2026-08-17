/// The offline intake path: a short branching questionnaire that resolves to
/// the same `CaseProfile` the reasoning agent produces.
///
/// It lives in the client on purpose. The agent needs a backend and an API key;
/// this needs neither, so somebody can always place themselves on the map —
/// and the answers never leave the device. It asks people to name a status
/// they already know rather than to describe a situation, which is exactly the
/// tradeoff: less forgiving of a messy story, but certain about a plain answer.
library;

import 'case_profile.dart';

class IntakeOption {
  const IntakeOption({
    required this.label,
    this.nodeId,
    this.next,
    this.alternatives = const [],
    this.confidence = 'high',
    this.note,
  });

  final String label;

  /// The status this answer resolves to. Null when the answer only narrows the
  /// question ([next]) or genuinely resolves to nothing.
  final String? nodeId;

  /// The follow-up step this answer leads to.
  final String? next;

  /// Other nodes worth showing when the answer is a direction rather than a
  /// destination ("a green card through work" is four routes, not one).
  final List<String> alternatives;

  final String confidence;

  /// Appended to the explanation, for answers that need a caveat.
  final String? note;

  bool get isTerminal => next == null;
}

class IntakeStep {
  const IntakeStep({
    required this.id,
    required this.prompt,
    required this.options,
    this.hint,
  });

  final String id;
  final String prompt;
  final String? hint;
  final List<IntakeOption> options;
}

/// The two short trees: one for "where are you now", one for "where do you
/// want to be". Both bottom out in real ids from `generic_pathways.json`.
class Questionnaire {
  const Questionnaire._();

  static const statusRoot = 'status';
  static const goalRoot = 'goal';

  static const steps = <String, IntakeStep>{
    statusRoot: IntakeStep(
      id: statusRoot,
      prompt: 'Which of these describes you today?',
      hint: 'Pick the closest one — you can change it later.',
      options: [
        IntakeOption(label: 'I am studying in the US on an F-1', next: 'f1'),
        IntakeOption(
          label: 'I am on a J-1 exchange program',
          nodeId: 'exchange.j1',
        ),
        IntakeOption(
          label: 'I am working in the US on a temporary work visa',
          next: 'work',
        ),
        IntakeOption(label: 'I am in the US through family', next: 'family'),
        IntakeOption(
          label: 'I have humanitarian protection, or I have applied for it',
          next: 'humanitarian',
        ),
        IntakeOption(label: 'I already have a green card', next: 'lpr'),
        IntakeOption(
          label: 'None of these',
          note:
              'Nothing was recorded as your current status. The map is still '
              'open to explore, and you can come back to this any time.',
        ),
      ],
    ),

    'f1': IntakeStep(
      id: 'f1',
      prompt: 'Which part of F-1 are you in?',
      options: [
        IntakeOption(
          label: 'Enrolled, not working off campus',
          nodeId: 'student.f1',
        ),
        IntakeOption(
          label: 'Working through CPT while enrolled',
          nodeId: 'student.cpt',
        ),
        IntakeOption(
          label: 'Pre-completion OPT',
          nodeId: 'student.opt_precompletion',
        ),
        IntakeOption(
          label: 'Post-completion OPT',
          nodeId: 'student.opt_postcompletion',
        ),
        IntakeOption(label: 'STEM OPT extension', nodeId: 'student.stem_opt'),
        IntakeOption(
          label: 'Cap-gap, with an H-1B petition pending',
          nodeId: 'student.cap_gap',
        ),
      ],
    ),

    'work': IntakeStep(
      id: 'work',
      prompt: 'Which work status?',
      options: [
        IntakeOption(label: 'H-1B', nodeId: 'temp_worker.h1b'),
        IntakeOption(
          label: 'L-1 intracompany transfer',
          nodeId: 'intracompany.l1',
        ),
        IntakeOption(label: 'TN under USMCA', nodeId: 'intracompany.tn'),
        IntakeOption(label: 'O-1 extraordinary ability', next: 'o1_category'),
        IntakeOption(label: 'E-2 treaty investor', nodeId: 'intracompany.e2'),
        IntakeOption(label: 'E-1 treaty trader', nodeId: 'intracompany.e1'),
        IntakeOption(
          label: 'P-1 athlete or entertainer',
          nodeId: 'extraordinary.p1',
        ),
        IntakeOption(label: 'R-1 religious worker', nodeId: 'temp_worker.r1'),
        IntakeOption(
          label: 'H-2A seasonal agricultural work',
          nodeId: 'temp_worker.h2a',
        ),
        IntakeOption(
          label: 'H-2B seasonal non-agricultural work',
          nodeId: 'temp_worker.h2b',
        ),
      ],
    ),

    'o1_category': IntakeStep(
      id: 'o1_category',
      prompt: 'Which best describes your field?',
      hint: 'This decides which O-1 evidence categories apply to you.',
      options: [
        IntakeOption(
          label: 'Sciences, education, business, or athletics',
          nodeId: 'extraordinary.o1a',
        ),
        IntakeOption(
          label: 'Arts, motion pictures, or television',
          nodeId: 'extraordinary.o1b',
        ),
        IntakeOption(
          label: 'Not sure',
          nodeId: 'extraordinary.o1',
          confidence: 'medium',
        ),
      ],
    ),

    'family': IntakeStep(
      id: 'family',
      prompt: 'Which describes the family relationship?',
      options: [
        IntakeOption(
          label: 'Married to a US citizen, adjusting status in the US',
          nodeId: 'family_gc.marriage_aos',
        ),
        IntakeOption(
          label: 'Spouse, parent or minor child of a US citizen',
          nodeId: 'family_gc.immediate_relative',
        ),
        IntakeOption(
          label: 'Spouse or minor child of a green-card holder',
          nodeId: 'family_gc.f2a',
        ),
        IntakeOption(
          label: 'On a K-1 fiancé(e) visa',
          nodeId: 'family_temp.k1',
        ),
        IntakeOption(
          label: 'Unmarried adult child of a US citizen',
          nodeId: 'family_gc.f1',
        ),
        IntakeOption(label: 'Sibling of a US citizen', nodeId: 'family_gc.f4'),
      ],
    ),

    'humanitarian': IntakeStep(
      id: 'humanitarian',
      prompt: 'Which protection?',
      options: [
        IntakeOption(label: 'Asylum', nodeId: 'humanitarian.asylum'),
        IntakeOption(label: 'Refugee status', nodeId: 'humanitarian.refugee'),
        IntakeOption(
          label: 'Temporary Protected Status (TPS)',
          nodeId: 'humanitarian.tps',
        ),
        IntakeOption(
          label: 'U status, as the victim of a crime',
          nodeId: 'humanitarian.u_visa',
        ),
        IntakeOption(
          label: 'T status, as a victim of trafficking',
          nodeId: 'humanitarian.t_visa',
        ),
        IntakeOption(label: 'VAWA self-petition', nodeId: 'humanitarian.vawa'),
        IntakeOption(
          label: 'Humanitarian parole',
          nodeId: 'humanitarian.parole',
        ),
      ],
    ),

    'lpr': IntakeStep(
      id: 'lpr',
      prompt: 'Which card do you hold?',
      options: [
        IntakeOption(
          label: 'A conditional, two-year card',
          nodeId: 'post_lpr.conditional_gc',
        ),
        IntakeOption(label: 'A ten-year card', nodeId: 'post_lpr.lpr'),
      ],
    ),

    goalRoot: IntakeStep(
      id: goalRoot,
      prompt: 'Where would you like to end up?',
      hint: 'A direction is enough — the map fills in the routes.',
      options: [
        IntakeOption(
          label: 'Keep working in the US for now',
          nodeId: 'temp_worker.h1b',
          alternatives: ['intracompany.l1', 'extraordinary.o1'],
          confidence: 'medium',
          note:
              'H-1B is the most common temporary work route; the map shows the '
              'others that may fit better.',
        ),
        IntakeOption(
          label: 'A green card through my work',
          nodeId: 'employment_gc.eb2',
          alternatives: [
            'employment_gc.eb1',
            'employment_gc.eb2_niw',
            'employment_gc.eb3',
          ],
          confidence: 'medium',
          note:
              'Which employment category fits depends on your role and '
              'qualifications — the map shows all of them.',
        ),
        IntakeOption(
          label: 'A green card through my family',
          nodeId: 'family_gc.marriage_aos',
          alternatives: ['family_gc.immediate_relative', 'family_gc.f2a'],
          confidence: 'medium',
        ),
        IntakeOption(
          label: 'A green card through investment',
          nodeId: 'employment_gc.eb5',
        ),
        IntakeOption(
          label: 'US citizenship',
          nodeId: 'post_lpr.naturalization',
        ),
        IntakeOption(
          label: 'Safety and protection in the US',
          nodeId: 'humanitarian.asylum',
          alternatives: ['humanitarian.tps'],
          confidence: 'medium',
        ),
        IntakeOption(
          label: 'I am not sure yet',
          note:
              'No goal recorded — the map shows everything still open to you.',
        ),
      ],
    ),
  };

  static IntakeStep step(String id) => steps[id]!;

  /// Folds the answers into the same shape the reasoning agent returns.
  ///
  /// [statusPath] and [goalPath] are the options chosen, in order. Confidence
  /// is high for a named status, because the person picked it themselves —
  /// the uncertainty in this path is whether the question was understood, not
  /// whether the answer was read correctly.
  static CaseProfile resolve({
    required List<IntakeOption> statusPath,
    required List<IntakeOption> goalPath,
  }) {
    final status = statusPath.isEmpty ? null : statusPath.last;
    final goal = goalPath.isEmpty ? null : goalPath.last;

    final notes = [
      for (final o in [...statusPath, ...goalPath])
        if (o.note != null) o.note!,
    ];

    final chosen = statusPath.map((o) => o.label).join(' → ');
    final explanation = [
      if (chosen.isNotEmpty) 'You told us: $chosen.',
      ...notes,
    ].join(' ');

    return CaseProfile(
      currentNodeId: status?.nodeId,
      currentConfidence: status?.nodeId == null ? 'low' : status!.confidence,
      goalNodeId: goal?.nodeId,
      goalConfidence: goal?.nodeId == null ? 'low' : goal!.confidence,
      alternativeGoalIds: goal?.alternatives ?? const [],
      facts: [
        for (final o in statusPath)
          CaseFact(label: 'You chose', value: o.label),
        if (goal != null) CaseFact(label: 'Aiming for', value: goal.label),
      ],
      explanation: explanation,
      source: CaseSource.questionnaire,
      updatedAt: DateTime.now(),
    );
  }
}
