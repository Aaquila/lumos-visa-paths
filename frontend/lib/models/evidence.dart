/// The O-1 / EB-1 evidence tracker's data model.
///
/// Two rules shape everything in this file.
///
///  * **The three visa families do not share a shape.** O-1A, O-1B and EB-1A
///    are criteria-counting categories. EB-1B is gated first and only then
///    counts. EB-1C counts nothing at all — it is a set of conditions that
///    generally all have to hold. [EvidenceStructure] exists so nothing in the
///    app can quietly assume "three out of ten" applies everywhere.
///  * **No documents, ever.** An [EvidenceAssessment] is a self-chosen strength
///    plus the user's own notes. There is no attachment field here, on purpose —
///    the product promises it never collects documents, and the way to keep that
///    promise is for the model to have nowhere to put one.
library;

import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Self-assessment
// ─────────────────────────────────────────────────────────────────────────────

/// How the user rates their own record on one criterion.
///
/// This is a self-assessment, not an eligibility finding. Nothing in Lumos
/// decides whether a criterion is actually met — USCIS does that, and only on a
/// filed petition.
enum EvidenceStrength {
  notStarted('not_started', 'Not started', 'Most people start here.'),
  inProgress(
    'in_progress',
    'In progress',
    'Something is underway — an application in, a draft started, a conversation open.',
  ),
  haveEvidence(
    'have_evidence',
    'I have something',
    'You could point to real evidence today, even if it is not your strongest.',
  ),
  strong(
    'strong',
    'Strong',
    'Well documented and independent — you would be comfortable leading with it.',
  );

  const EvidenceStrength(this.id, this.label, this.blurb);

  final String id;
  final String label;
  final String blurb;

  /// Counts toward the threshold. "Plausibly met" is the strongest claim this
  /// product makes — the user said they have evidence, and that is all.
  bool get isPlausiblyMet =>
      this == EvidenceStrength.haveEvidence || this == EvidenceStrength.strong;

  /// Underway but not yet evidence. Worth surfacing separately: these are
  /// usually the cheapest things to finish.
  bool get isMoving => this == EvidenceStrength.inProgress;

  static EvidenceStrength fromId(String? id) => EvidenceStrength.values
      .firstWhere((s) => s.id == id, orElse: () => EvidenceStrength.notStarted);
}

/// One person's answer about one criterion. Local to their browser, always.
@immutable
class EvidenceAssessment {
  const EvidenceAssessment({
    required this.itemId,
    this.strength = EvidenceStrength.notStarted,
    this.notes = '',
    this.updatedAt,
  });

  final String itemId;
  final EvidenceStrength strength;

  /// The user's own words. Never sent anywhere.
  final String notes;

  final DateTime? updatedAt;

  bool get isEmpty =>
      strength == EvidenceStrength.notStarted && notes.trim().isEmpty;

  EvidenceAssessment copyWith({EvidenceStrength? strength, String? notes}) =>
      EvidenceAssessment(
        itemId: itemId,
        strength: strength ?? this.strength,
        notes: notes ?? this.notes,
        updatedAt: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'strength': strength.id,
    'notes': notes,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  factory EvidenceAssessment.fromJson(Map<String, dynamic> j) =>
      EvidenceAssessment(
        itemId: j['itemId'] as String? ?? '',
        strength: EvidenceStrength.fromId(j['strength'] as String?),
        notes: j['notes'] as String? ?? '',
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// The reference data
// ─────────────────────────────────────────────────────────────────────────────

/// How a category is actually judged. The whole point of this enum is that
/// [qualifyingConditions] and [gatedCriteria] must never be scored as though
/// they were [criteriaCount].
enum EvidenceStructure {
  /// "At least N of the following" — O-1A, O-1B.
  criteriaCount('criteria_count'),

  /// "At least N of the following", and then a separate final merits
  /// determination on the record as a whole — EB-1A.
  criteriaCountWithFinalMerits('criteria_count_with_final_merits'),

  /// Gating requirements that all have to hold, and only then "at least N of
  /// the following" — EB-1B.
  gatedCriteria('gated_criteria'),

  /// No counting at all: conditions that generally all have to be true —
  /// EB-1C.
  qualifyingConditions('qualifying_conditions');

  const EvidenceStructure(this.id);
  final String id;

  /// True only where a "N of M criteria" count is a meaningful score on its
  /// own. Deliberately false for [gatedCriteria] and [qualifyingConditions].
  bool get isCriteriaCounted =>
      this == EvidenceStructure.criteriaCount ||
      this == EvidenceStructure.criteriaCountWithFinalMerits;

  /// True where unmet gates or conditions veto the outcome regardless of any
  /// criteria count.
  bool get hasHardGates =>
      this == EvidenceStructure.gatedCriteria ||
      this == EvidenceStructure.qualifyingConditions;

  static EvidenceStructure fromId(String? id) =>
      EvidenceStructure.values.firstWhere(
        (s) => s.id == id,
        orElse: () => EvidenceStructure.criteriaCount,
      );
}

/// What kind of thing the user is assessing.
enum EvidenceItemKind {
  /// One of the "at least N of these" list.
  criterion,

  /// A gating requirement that must hold before the criteria matter (EB-1B).
  gate,

  /// A qualifying condition that generally must be true (EB-1C).
  condition,
}

/// Rough cost of moving a criterion from nothing to something. Used only to
/// rank suggestions — it is never shown as a promise.
enum BuildEffort {
  weeks('weeks', 'Weeks', 3),
  months('months', 'Months', 2),
  years('years', 'Longer — often a year or more', 1);

  const BuildEffort(this.id, this.label, this.reachability);

  final String id;
  final String label;

  /// Higher means easier to move soon.
  final int reachability;

  static BuildEffort fromId(String? id) => BuildEffort.values.firstWhere(
    (e) => e.id == id,
    orElse: () => BuildEffort.months,
  );
}

/// One criterion, gating requirement, or qualifying condition.
@immutable
class EvidenceItem {
  const EvidenceItem({
    required this.id,
    required this.setId,
    required this.kind,
    required this.name,
    required this.means,
    this.key = '',
    this.category = '',
    this.typicallyCounts = const [],
    this.typicallyDoesNotCount = const [],
    this.howToBuild = const [],
    this.timeToBuild = '',
    this.effort = BuildEffort.months,
    this.applicabilityNote,
  });

  final String id;
  final String setId;
  final EvidenceItemKind kind;

  /// Stable short key, shared across sets where the criterion is the same idea
  /// (`awards`, `judging`, …).
  final String key;
  final String category;

  /// Plain-English name.
  final String name;

  /// What it actually means, in normal words.
  final String means;

  final List<String> typicallyCounts;

  /// What typically does *not* count. This is the most valuable list on the
  /// screen — it is where people lose years.
  final List<String> typicallyDoesNotCount;

  final List<String> howToBuild;
  final String timeToBuild;
  final BuildEffort effort;

  /// Set where a criterion only applies to some fields (the EB-1A exhibitions
  /// and performing-arts criteria). Shown so nobody feels behind for skipping
  /// something that was never meant for them.
  final String? applicabilityNote;

  bool get isCountable => kind == EvidenceItemKind.criterion;
  bool get isMandatory => kind != EvidenceItemKind.criterion;

  factory EvidenceItem.fromJson(
    Map<String, dynamic> j, {
    required String setId,
    required EvidenceItemKind kind,
  }) => EvidenceItem(
    id: j['id'] as String? ?? '',
    setId: setId,
    kind: kind,
    key: j['key'] as String? ?? '',
    category: j['category'] as String? ?? '',
    name: j['name'] as String? ?? '',
    means: j['means'] as String? ?? j['description'] as String? ?? '',
    typicallyCounts: _strings(j['typically_counts']),
    typicallyDoesNotCount: _strings(j['typically_does_not_count']),
    howToBuild: _strings(j['how_to_build']),
    timeToBuild: j['time_to_build'] as String? ?? '',
    effort: BuildEffort.fromId(j['build_effort'] as String?),
    applicabilityNote: j['applicability_note'] as String?,
  );
}

/// The single-award shortcut some categories offer.
@immutable
class OneTimeAchievement {
  const OneTimeAchievement({
    required this.id,
    required this.name,
    required this.means,
    this.note,
  });

  final String id;
  final String name;
  final String means;
  final String? note;

  static OneTimeAchievement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    return OneTimeAchievement(
      id: j['id'] as String? ?? '',
      name: j['name'] as String? ?? '',
      means: j['means'] as String? ?? j['description'] as String? ?? '',
      note: j['note'] as String?,
    );
  }
}

/// The EB-1A two-step structure, modelled explicitly because it is the thing
/// applicants most often misunderstand: meeting three criteria is step one, and
/// step two is a different question entirely.
@immutable
class TwoStepExplainer {
  const TwoStepExplainer({
    required this.stepOneName,
    required this.stepOneMeans,
    required this.stepTwoName,
    required this.stepTwoMeans,
    this.stepOneNote,
    this.stepTwoNote,
    this.whyItMatters = '',
  });

  final String stepOneName;
  final String stepOneMeans;
  final String? stepOneNote;
  final String stepTwoName;
  final String stepTwoMeans;
  final String? stepTwoNote;
  final String whyItMatters;

  static TwoStepExplainer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final one = (j['step_one'] as Map?)?.cast<String, dynamic>() ?? const {};
    final two = (j['step_two'] as Map?)?.cast<String, dynamic>() ?? const {};
    return TwoStepExplainer(
      stepOneName: one['name'] as String? ?? 'Step one',
      stepOneMeans: one['means'] as String? ?? '',
      stepOneNote: one['note'] as String?,
      stepTwoName: two['name'] as String? ?? 'Step two',
      stepTwoMeans: two['means'] as String? ?? '',
      stepTwoNote: two['note'] as String?,
      whyItMatters: j['why_it_matters'] as String? ?? '',
    );
  }
}

/// One visa category's evidence structure.
@immutable
class EvidenceSet {
  const EvidenceSet({
    required this.id,
    required this.visaCode,
    required this.title,
    required this.structure,
    required this.summary,
    this.pathwayNodeId,
    this.threshold,
    this.sponsorship = '',
    this.howItIsJudged = '',
    this.structureExplainer,
    this.twoStepNote,
    this.finalMeritsNote,
    this.uncertaintyNote,
    this.encouragement = '',
    this.criteria = const [],
    this.gates = const [],
    this.conditions = const [],
    this.oneTimeAchievement,
    this.twoStep,
  });

  final String id;
  final String visaCode;
  final String title;

  /// Links back to the node of the same status on `/visa-pathways`.
  final String? pathwayNodeId;

  final EvidenceStructure structure;

  /// How many criteria typically need to be met. Null where counting does not
  /// apply at all (EB-1C).
  final int? threshold;

  final String sponsorship;
  final String summary;
  final String howItIsJudged;

  /// Why this category is shaped the way it is — shown for EB-1B and EB-1C,
  /// where the shape itself is the thing people get wrong.
  final String? structureExplainer;

  final String? twoStepNote;
  final String? finalMeritsNote;

  /// Where the reference data is honestly unsure. Shown rather than hidden.
  final String? uncertaintyNote;

  final String encouragement;

  final List<EvidenceItem> criteria;
  final List<EvidenceItem> gates;
  final List<EvidenceItem> conditions;

  final OneTimeAchievement? oneTimeAchievement;
  final TwoStepExplainer? twoStep;

  /// Everything the user can assess, mandatory items first.
  List<EvidenceItem> get allItems => [...gates, ...conditions, ...criteria];

  EvidenceItem? item(String id) {
    for (final i in allItems) {
      if (i.id == id) return i;
    }
    return null;
  }

  factory EvidenceSet.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String? ?? '';
    List<EvidenceItem> parse(Object? raw, EvidenceItemKind kind) =>
        (raw is List ? raw : const [])
            .whereType<Map>()
            .map(
              (e) => EvidenceItem.fromJson(
                e.cast<String, dynamic>(),
                setId: id,
                kind: kind,
              ),
            )
            .toList(growable: false);

    return EvidenceSet(
      id: id,
      visaCode: j['visa_code'] as String? ?? id.toUpperCase(),
      title: j['title'] as String? ?? '',
      pathwayNodeId: j['pathway_node_id'] as String?,
      structure: EvidenceStructure.fromId(j['structure'] as String?),
      threshold: j['threshold'] as int?,
      sponsorship: j['sponsorship'] as String? ?? '',
      summary: j['summary'] as String? ?? '',
      howItIsJudged: j['how_it_is_judged'] as String? ?? '',
      structureExplainer: j['structure_explainer'] as String?,
      twoStepNote: j['two_step_note'] as String?,
      finalMeritsNote: j['final_merits_note'] as String?,
      uncertaintyNote: j['uncertainty_note'] as String?,
      encouragement: j['encouragement'] as String? ?? '',
      criteria: parse(j['criteria'], EvidenceItemKind.criterion),
      gates: parse(j['gates'], EvidenceItemKind.gate),
      conditions: parse(j['conditions'], EvidenceItemKind.condition),
      oneTimeAchievement: OneTimeAchievement.fromJson(
        j['one_time_achievement_alternative'],
      ),
      twoStep: TwoStepExplainer.fromJson(j['two_step']),
    );
  }
}

/// Header material shown once, not per criterion — including the disclaimer,
/// which is not optional on a screen about immigration law.
@immutable
class EvidenceMeta {
  const EvidenceMeta({
    this.title = '',
    this.asOf = '',
    this.disclaimer = '',
    this.warning = '',
    this.privacyNote = '',
    this.selfAssessmentNote = '',
  });

  final String title;
  final String asOf;
  final String disclaimer;
  final String warning;
  final String privacyNote;
  final String selfAssessmentNote;

  factory EvidenceMeta.fromJson(Map<String, dynamic> j) => EvidenceMeta(
    title: j['title'] as String? ?? '',
    asOf: j['as_of'] as String? ?? '',
    disclaimer: j['disclaimer'] as String? ?? '',
    warning: j['warning'] as String? ?? '',
    privacyNote: j['privacy_note'] as String? ?? '',
    selfAssessmentNote: j['self_assessment_note'] as String? ?? '',
  );
}

/// The parsed reference file.
@immutable
class EvidenceCatalog {
  const EvidenceCatalog({required this.meta, required this.sets});

  final EvidenceMeta meta;
  final List<EvidenceSet> sets;

  EvidenceSet? set(String id) {
    for (final s in sets) {
      if (s.id == id) return s;
    }
    return null;
  }

  EvidenceItem? item(String itemId) {
    for (final s in sets) {
      final found = s.item(itemId);
      if (found != null) return found;
    }
    return null;
  }

  factory EvidenceCatalog.fromJson(Map<String, dynamic> j) => EvidenceCatalog(
    meta: EvidenceMeta.fromJson(
      (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    sets: (j['sets'] is List ? j['sets'] as List : const [])
        .whereType<Map>()
        .map((e) => EvidenceSet.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Readiness
// ─────────────────────────────────────────────────────────────────────────────

/// Where somebody stands on one category.
///
/// Never a score out of ten and never a verdict. [headline] states the gap
/// plainly; [encouragement] makes zero an acceptable place to be, because for
/// most people on their first read it is.
@immutable
class EvidenceReadiness {
  const EvidenceReadiness({
    required this.setId,
    required this.visaCode,
    required this.structure,
    required this.headline,
    required this.detail,
    required this.progress,
    required this.meetsTypicalThreshold,
    this.threshold,
    this.criteriaTotal = 0,
    this.criteriaMet = 0,
    this.criteriaMoving = 0,
    this.mandatoryTotal = 0,
    this.mandatoryMet = 0,
    this.answered = 0,
    this.totalItems = 0,
    this.encouragement = '',
  });

  final String setId;
  final String visaCode;
  final EvidenceStructure structure;

  /// The gap, said plainly. "One more to go", not "33%".
  final String headline;

  /// A second line explaining what the headline means for this structure.
  final String detail;

  /// 0..1, for a progress bar only. Never rendered as a percentage score.
  final double progress;

  /// Whether the *typical* threshold looks met on the user's own assessment.
  /// For gated and condition-based categories this also requires every
  /// mandatory item, which is the whole reason it is computed per structure.
  final bool meetsTypicalThreshold;

  final int? threshold;
  final int criteriaTotal;
  final int criteriaMet;
  final int criteriaMoving;

  /// Gates (EB-1B) or conditions (EB-1C).
  final int mandatoryTotal;
  final int mandatoryMet;

  final int answered;
  final int totalItems;
  final String encouragement;

  /// True only where "N of M criteria" is the actual scoring model.
  bool get isCriteriaCounted => structure.isCriteriaCounted;

  /// How many more criteria are typically needed. Null where counting does not
  /// apply.
  int? get criteriaGap {
    final t = threshold;
    if (t == null || !structure.isCriteriaCounted && !structure.hasHardGates) {
      return null;
    }
    if (t == 0) return null;
    final gap = t - criteriaMet;
    return gap < 0 ? 0 : gap;
  }

  bool get hasStarted => answered > 0;
}

/// A suggested next move: the cheapest thing that would actually change this
/// person's position.
@immutable
class EvidenceNextAction {
  const EvidenceNextAction({
    required this.item,
    required this.rationale,
    required this.score,
    required this.currentStrength,
  });

  final EvidenceItem item;

  /// Why this one, in the user's terms.
  final String rationale;

  /// Internal ranking weight. Exposed so the ordering is testable.
  final int score;

  final EvidenceStrength currentStrength;

  String get setId => item.setId;
}

List<String> _strings(Object? raw) =>
    (raw is List ? raw : const []).whereType<String>().toList(growable: false);
