/// What Lumos asks a new person before it asks them anything hard.
///
/// Two steps, both deliberately low-stakes:
///
///  1. **A name to be called by.** Three fixed choices, tapped — never typed.
///     A free-text name box is a small demand that lands badly on somebody who
///     is already overwhelmed, and this handle is not a legal name, so there is
///     nothing to get "right". The choice is an id from [NameChoice.options],
///     which keeps the stored value a closed set rather than user text.
///  2. **Their visa situation, in their own words.** Free text is the primary
///     input by product rule: people describe their status the way they live it
///     ("my OPT started in June"), not the way a form codes it. Chips are a
///     shortcut, never a requirement, and every field here is skippable.
///
/// Everything is optional and nothing blocks progress — [situationDone] records
/// that step 2 was *seen through*, whether it was answered or skipped, so the
/// router never traps somebody in a loop they chose to leave.
library;

/// Which cartoon face a [NameChoice] wears. Drawn in pure Dart by
/// `CartoonAvatar`, so there is no asset pipeline and no photograph of a person.
enum AvatarKind { flower, star, sprout }

/// One of the three names on offer.
class NameChoice {
  const NameChoice({
    required this.id,
    required this.name,
    required this.avatar,
    required this.blurb,
  });

  final String id;
  final String name;
  final AvatarKind avatar;

  /// One friendly line under the name. Not a gender label — the set spans
  /// traditionally feminine, traditionally masculine and neutral without
  /// announcing which is which, because the user does not owe us that.
  final String blurb;

  /// The three, in the order they are shown.
  static const options = <NameChoice>[
    NameChoice(
      id: 'mira',
      name: 'Mira',
      avatar: AvatarKind.flower,
      blurb: 'Short and bright.',
    ),
    NameChoice(
      id: 'theo',
      name: 'Theo',
      avatar: AvatarKind.star,
      blurb: 'Easy to say.',
    ),
    NameChoice(
      id: 'robin',
      name: 'Robin',
      avatar: AvatarKind.sprout,
      blurb: 'Works for anyone.',
    ),
  ];

  static NameChoice? byId(String? id) {
    if (id == null) return null;
    for (final option in options) {
      if (option.id == id) return option;
    }
    return null;
  }
}

/// Step 2: where they are, when it changes, where they want to get to.
class VisaSituation {
  const VisaSituation({
    this.statusText = '',
    this.statusChip,
    this.changeYear,
    this.changeMonth,
    this.dateUnknown = false,
    this.goalText = '',
    this.goalChip,
  });

  /// The primary answer to "what are you on right now", in their words.
  final String statusText;

  /// An optional quick-pick shortcut ("F-1", "not sure"). A label, not a code:
  /// it is shown back to the person and passed to intake as more prose.
  final String? statusChip;

  /// When it changes or expires. Month is optional on purpose — "some time in
  /// 2026" is a real answer and must not be rounded into a false precision.
  final int? changeYear;
  final int? changeMonth;

  /// They said outright that they do not know. Different from simply leaving
  /// it blank, and worth keeping so nothing nags them for it later.
  final bool dateUnknown;

  /// What they would like their situation to become.
  final String goalText;
  final String? goalChip;

  bool get hasStatus =>
      statusText.trim().isNotEmpty || (statusChip?.isNotEmpty ?? false);
  bool get hasGoal =>
      goalText.trim().isNotEmpty || (goalChip?.isNotEmpty ?? false);
  bool get hasDate => dateUnknown || changeYear != null;
  bool get isEmpty => !hasStatus && !hasGoal && !hasDate;

  /// True when status has been answered comprehensively (not just a guess).
  /// Requires either typed text or a specific chip selection.
  bool get hasComprehensiveStatus {
    if (statusChip == null || statusChip == 'Other / not sure') return false;
    return statusText.trim().isNotEmpty || statusChip!.isNotEmpty;
  }

  /// True when goal has been answered comprehensively (not just a guess).
  bool get hasComprehensiveGoal {
    if (goalChip == null || goalChip == 'Not sure yet') return false;
    return goalText.trim().isNotEmpty || goalChip!.isNotEmpty;
  }

  /// The status as one sentence, for pre-filling intake and for showing back.
  String get statusSummary {
    final chip = statusChip?.trim() ?? '';
    final text = statusText.trim();
    if (chip.isEmpty) return text;
    if (text.isEmpty) return chip;
    return '$chip. $text';
  }

  String get goalSummary {
    final chip = goalChip?.trim() ?? '';
    final text = goalText.trim();
    if (chip.isEmpty) return text;
    if (text.isEmpty) return chip;
    return '$chip. $text';
  }

  /// How the date reads in a sentence. Empty when nothing was given.
  String get dateSummary {
    if (dateUnknown) return 'I am not sure when it changes.';
    final year = changeYear;
    if (year == null) return '';
    final month = changeMonth;
    if (month == null || month < 1 || month > 12) {
      return 'It changes some time in $year.';
    }
    return 'It changes around ${monthNames[month - 1]} $year.';
  }

  static const monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  VisaSituation copyWith({
    String? statusText,
    String? statusChip,
    int? changeYear,
    int? changeMonth,
    bool? dateUnknown,
    String? goalText,
    String? goalChip,
    bool clearStatusChip = false,
    bool clearGoalChip = false,
    bool clearDate = false,
  }) => VisaSituation(
    statusText: statusText ?? this.statusText,
    statusChip: clearStatusChip ? null : (statusChip ?? this.statusChip),
    changeYear: clearDate ? null : (changeYear ?? this.changeYear),
    changeMonth: clearDate ? null : (changeMonth ?? this.changeMonth),
    dateUnknown: clearDate ? false : (dateUnknown ?? this.dateUnknown),
    goalText: goalText ?? this.goalText,
    goalChip: clearGoalChip ? null : (goalChip ?? this.goalChip),
  );

  Map<String, dynamic> toJson() => {
    'status_text': statusText,
    'status_chip': statusChip,
    'change_year': changeYear,
    'change_month': changeMonth,
    'date_unknown': dateUnknown,
    'goal_text': goalText,
    'goal_chip': goalChip,
  };

  factory VisaSituation.fromJson(Map<String, dynamic> j) => VisaSituation(
    statusText: j['status_text'] as String? ?? '',
    statusChip: j['status_chip'] as String?,
    changeYear: (j['change_year'] as num?)?.toInt(),
    changeMonth: (j['change_month'] as num?)?.toInt(),
    dateUnknown: j['date_unknown'] as bool? ?? false,
    goalText: j['goal_text'] as String? ?? '',
    goalChip: j['goal_chip'] as String?,
  );

  /// The quick-pick shortcuts. Plain labels, because they are shown to the
  /// person and read back to them — no visa codes leak into the copy alone.
  static const statusChips = [
    'F-1 student',
    'H-1B',
    'L-1',
    'O-1',
    'J-1',
    'B-1/B-2 visitor',
    'Green card',
    'Other / not sure',
  ];

  static const goalChips = [
    'Keep working here',
    'A green card',
    'Citizenship one day',
    'Study something new',
    'Stay safe here',
    'Not sure yet',
  ];
}

/// The onboarding record carried on the signed-in session.
class OnboardingProfile {
  const OnboardingProfile({
    this.chosenNameId,
    this.situation,
    this.situationDone = false,
  });

  static const empty = OnboardingProfile();

  /// An id from [NameChoice.options]. Null until step 1 is done.
  final String? chosenNameId;

  /// Null when step 2 was skipped outright or has not happened yet.
  final VisaSituation? situation;

  /// True once step 2 has been finished *or* deliberately skipped.
  final bool situationDone;

  NameChoice? get choice => NameChoice.byId(chosenNameId);
  String? get chosenName => choice?.name;
  bool get hasName => choice != null;
  bool get isComplete => hasName && situationDone;

  /// Where a half-finished person should be sent. Null when there is nothing
  /// left to ask.
  String? get resumeRoute {
    if (!hasName) return '/onboarding/name';
    if (!situationDone) return '/onboarding/situation';
    return null;
  }

  OnboardingProfile copyWith({
    String? chosenNameId,
    VisaSituation? situation,
    bool? situationDone,
    bool clearName = false,
    bool clearSituation = false,
  }) => OnboardingProfile(
    chosenNameId: clearName ? null : (chosenNameId ?? this.chosenNameId),
    situation: clearSituation ? null : (situation ?? this.situation),
    situationDone: situationDone ?? this.situationDone,
  );

  Map<String, dynamic> toJson() => {
    'chosen_name_id': chosenNameId,
    'situation': situation?.toJson(),
    'situation_done': situationDone,
  };

  factory OnboardingProfile.fromJson(Map<String, dynamic> j) {
    final raw = j['situation'];
    return OnboardingProfile(
      // An unknown id (a name we later removed) reads as "not chosen yet"
      // rather than as a broken label on the dashboard.
      chosenNameId: NameChoice.byId(j['chosen_name_id'] as String?)?.id,
      situation: raw is Map
          ? VisaSituation.fromJson(raw.cast<String, dynamic>())
          : null,
      situationDone: j['situation_done'] as bool? ?? false,
    );
  }
}
