/// What the intake step worked out: where a person is on the map, and where
/// they said they want to be.
///
/// This is a *proposal the person accepted*, not a verified case file. It is
/// stored on the device until the backend's `POST /api/case/confirm` exists —
/// see `backend/docs/API_ENDPOINTS.md` §3 — and the shape here is the one that
/// endpoint returns, so the swap is a repository change, not a model change.
library;

class CaseFact {
  const CaseFact({required this.label, required this.value});

  final String label;
  final String value;

  Map<String, dynamic> toJson() => {'label': label, 'value': value};

  factory CaseFact.fromJson(Map<String, dynamic> j) => CaseFact(
    label: j['label'] as String? ?? '',
    value: j['value'] as String? ?? '',
  );
}

/// How the current status or goal was arrived at. Shown to the person, because
/// a keyword guess and a reasoned reading deserve different amounts of trust.
enum CaseSource {
  /// The reasoning agent read a free-text description.
  agent,

  /// The backend's keyword fallback matched a status by name.
  keywords,

  /// The person answered the built-in questionnaire — no service involved.
  questionnaire;

  static CaseSource parse(String? raw) => switch (raw) {
    'llm' || 'agent' => CaseSource.agent,
    'keywords' => CaseSource.keywords,
    _ => CaseSource.questionnaire,
  };

  String get wire => switch (this) {
    CaseSource.agent => 'llm',
    CaseSource.keywords => 'keywords',
    CaseSource.questionnaire => 'questionnaire',
  };

  String get label => switch (this) {
    CaseSource.agent => 'Read from your description',
    CaseSource.keywords => 'Matched by keyword',
    CaseSource.questionnaire => 'From your answers',
  };
}

class CaseProfile {
  const CaseProfile({
    this.currentNodeId,
    this.currentConfidence = 'low',
    this.goalNodeId,
    this.goalConfidence = 'low',
    this.alternativeGoalIds = const [],
    this.facts = const [],
    this.questions = const [],
    this.explanation = '',
    this.source = CaseSource.questionnaire,
    this.degraded = false,
    required this.updatedAt,
  });

  /// Where the person is today. Null when nothing in the intake identified a
  /// status — an unanswered question, not a default.
  final String? currentNodeId;
  final String currentConfidence;

  /// Where they said they want to end up. Null far more often than
  /// [currentNodeId]: plenty of people know their situation and not their
  /// destination, and the product must not invent one for them.
  final String? goalNodeId;
  final String goalConfidence;

  /// Other endpoints that fit the direction they described.
  final List<String> alternativeGoalIds;

  final List<CaseFact> facts;

  /// What intake still needs answered to be sure. Surfaced rather than
  /// silently resolved.
  final List<String> questions;

  final String explanation;
  final CaseSource source;

  /// True when the reasoner was unreachable and a weaker resolver stood in.
  final bool degraded;

  final DateTime updatedAt;

  bool get isResolved => currentNodeId != null;
  bool get hasGoal => goalNodeId != null;

  CaseProfile copyWith({
    String? currentNodeId,
    String? goalNodeId,
    String? goalConfidence,
    List<String>? alternativeGoalIds,
    bool clearGoal = false,
  }) => CaseProfile(
    currentNodeId: currentNodeId ?? this.currentNodeId,
    currentConfidence: currentConfidence,
    goalNodeId: clearGoal ? null : (goalNodeId ?? this.goalNodeId),
    goalConfidence: goalConfidence ?? this.goalConfidence,
    alternativeGoalIds: alternativeGoalIds ?? this.alternativeGoalIds,
    facts: facts,
    questions: questions,
    explanation: explanation,
    source: source,
    degraded: degraded,
    updatedAt: DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'current_node_id': currentNodeId,
    'current_confidence': currentConfidence,
    'goal_node_id': goalNodeId,
    'goal_confidence': goalConfidence,
    'alternative_goal_ids': alternativeGoalIds,
    'facts': [for (final f in facts) f.toJson()],
    'questions': questions,
    'explanation': explanation,
    'source': source.wire,
    'degraded': degraded,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory CaseProfile.fromJson(Map<String, dynamic> j) => CaseProfile(
    currentNodeId: j['current_node_id'] as String?,
    currentConfidence: j['current_confidence'] as String? ?? 'low',
    goalNodeId: j['goal_node_id'] as String?,
    goalConfidence: j['goal_confidence'] as String? ?? 'low',
    alternativeGoalIds: [
      for (final id in (j['alternative_goal_ids'] as List? ?? const []))
        id as String,
    ],
    facts: [
      for (final f in (j['facts'] as List? ?? const []))
        CaseFact.fromJson((f as Map).cast<String, dynamic>()),
    ],
    // The API sends question objects; storage keeps only the text, which is
    // all the UI shows until answering them writes back to the case.
    questions: [
      for (final q in (j['questions'] as List? ?? const []))
        if (q is String) q else ((q as Map)['text'] as String? ?? ''),
    ]..removeWhere((q) => q.isEmpty),
    explanation: j['explanation'] as String? ?? '',
    source: CaseSource.parse(j['source'] as String?),
    degraded: j['degraded'] as bool? ?? false,
    updatedAt:
        DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.now(),
  );
}
