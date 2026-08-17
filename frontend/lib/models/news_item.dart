import 'package:flutter/foundation.dart';

import 'onboarding_profile.dart';

/// Structured publisher metadata. Mirrors `DocumentMeta` in the backend.
///
/// Empty for the scraped HTML sources; populated for anything from the Federal
/// Register API, which is where the backend's relevance scoring gets most of
/// its confidence.
@immutable
class DocumentMeta {
  const DocumentMeta({
    this.documentType = '',
    this.action = '',
    this.agencies = const [],
    this.cfrReferences = const [],
    this.effectiveOn,
    this.commentsCloseOn,
  });

  static const empty = DocumentMeta();

  /// Rule | Proposed Rule | Notice | Presidential Document.
  final String documentType;
  final String action;
  final List<String> agencies;
  final List<String> cfrReferences;
  final DateTime? effectiveOn;
  final DateTime? commentsCloseOn;

  factory DocumentMeta.fromJson(Map<String, dynamic> j) => DocumentMeta(
    documentType: j['document_type'] as String? ?? '',
    action: j['action'] as String? ?? '',
    agencies: (j['agencies'] as List? ?? const []).cast<String>(),
    cfrReferences: (j['cfr_references'] as List? ?? const []).cast<String>(),
    effectiveOn: DateTime.tryParse(j['effective_on'] as String? ?? ''),
    commentsCloseOn: DateTime.tryParse(j['comments_close_on'] as String? ?? ''),
  );
}

/// One scraped policy update. Mirrors `NewsItem` in `backend/app/models.py`.
@immutable
class NewsItem {
  const NewsItem({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.title,
    required this.url,
    this.summary = '',
    this.publishedAt,
    this.firstSeenAt,
    this.matchedNodes = const [],
    this.tags = const [],
    this.meta = DocumentMeta.empty,
  });

  final String id;
  final String sourceId;
  final String sourceName;
  final String title;
  final String url;
  final String summary;

  /// The date printed by the publisher. Null when none could be read — the
  /// backend parses dates but never invents them.
  final DateTime? publishedAt;
  final DateTime? firstSeenAt;

  /// Pathway node ids this update was matched to.
  final List<String> matchedNodes;
  final List<String> tags;
  final DocumentMeta meta;

  DateTime? get date => publishedAt ?? firstSeenAt;

  factory NewsItem.fromJson(Map<String, dynamic> j) => NewsItem(
    id: j['id'] as String,
    sourceId: j['source_id'] as String? ?? '',
    sourceName: j['source_name'] as String? ?? '',
    title: j['title'] as String? ?? '',
    url: j['url'] as String? ?? '',
    summary: j['summary'] as String? ?? '',
    publishedAt: DateTime.tryParse(j['published_at'] as String? ?? ''),
    firstSeenAt: DateTime.tryParse(j['first_seen_at'] as String? ?? ''),
    matchedNodes: (j['matched_nodes'] as List? ?? const []).cast<String>(),
    tags: (j['tags'] as List? ?? const []).cast<String>(),
    meta: j['meta'] is Map
        ? DocumentMeta.fromJson((j['meta'] as Map).cast<String, dynamic>())
        : DocumentMeta.empty,
  );
}

/// How relevant one update is to one person. Mirrors `RelevanceVerdict`.
///
/// Three bands, in the order the page shows them. The strings are the
/// backend's own — matching on them rather than on an index means a new band
/// degrades to "unknown" instead of silently rendering as the wrong one.
enum Relevance {
  affectsYou('affects_you'),
  worthKnowing('worth_knowing'),
  background('background');

  const Relevance(this.wire);
  final String wire;

  static Relevance parse(String? value) => switch (value) {
    'affects_you' => Relevance.affectsYou,
    'worth_knowing' => Relevance.worthKnowing,
    _ => Relevance.background,
  };
}

/// One matched signal, so the ranking can be shown rather than asserted.
@immutable
class RelevanceSignal {
  const RelevanceSignal({
    required this.kind,
    required this.label,
    this.foundIn = '',
  });

  final String kind;
  final String label;
  final String foundIn;

  factory RelevanceSignal.fromJson(Map<String, dynamic> j) => RelevanceSignal(
    kind: j['kind'] as String? ?? '',
    label: j['label'] as String? ?? '',
    foundIn: j['found_in'] as String? ?? '',
  );
}

@immutable
class RelevanceVerdict {
  const RelevanceVerdict({
    required this.level,
    this.confidence = 0,
    this.reason = '',
    this.whatThisMeans = '',
    this.signals = const [],
    this.touchesNodes = const [],
    this.touchesDeadlines = const [],
  });

  static const none = RelevanceVerdict(level: Relevance.background);

  final Relevance level;
  final double confidence;

  /// The concrete signal behind the band. Never empty from the backend.
  final String reason;

  /// Two or three sentences addressed to the reader. The point of the feature.
  final String whatThisMeans;

  final List<RelevanceSignal> signals;
  final List<String> touchesNodes;

  /// Dates on this item that could move the reader's own timeline. Words, not
  /// a computed deadline — the backend does not manufacture deadlines.
  final List<String> touchesDeadlines;

  factory RelevanceVerdict.fromJson(Map<String, dynamic> j) => RelevanceVerdict(
    level: Relevance.parse(j['level'] as String?),
    confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
    reason: j['reason'] as String? ?? '',
    whatThisMeans: j['what_this_means'] as String? ?? '',
    signals: [
      for (final s in (j['signals'] as List? ?? const []))
        RelevanceSignal.fromJson((s as Map).cast<String, dynamic>()),
    ],
    touchesNodes: (j['touches_nodes'] as List? ?? const []).cast<String>(),
    touchesDeadlines: (j['touches_deadlines'] as List? ?? const [])
        .cast<String>(),
  );
}

/// An item with its verdict. Mirrors `RelevantNewsItem`.
@immutable
class ScoredNewsItem {
  const ScoredNewsItem({required this.item, required this.relevance});

  final NewsItem item;
  final RelevanceVerdict relevance;

  factory ScoredNewsItem.fromJson(Map<String, dynamic> j) => ScoredNewsItem(
    item: NewsItem.fromJson((j['item'] as Map).cast<String, dynamic>()),
    relevance: j['relevance'] is Map
        ? RelevanceVerdict.fromJson(
            (j['relevance'] as Map).cast<String, dynamic>(),
          )
        : RelevanceVerdict.none,
  );
}

/// The feed sorted around one person. Mirrors `PersonalisedNewsFeed`.
@immutable
class RelevantNewsFeed {
  const RelevantNewsFeed({
    this.items = const [],
    this.total = 0,
    this.counts = const {},
    this.lastScrapedAt,
    this.stale = false,
    this.personalised = false,
    this.disclaimer = '',
    this.offline = false,
  });

  static const empty = RelevantNewsFeed();

  final List<ScoredNewsItem> items;
  final int total;

  /// Level → count. Always all three keys from the backend, so an empty
  /// "affects you" band is something the UI can state rather than infer.
  final Map<String, int> counts;

  final DateTime? lastScrapedAt;
  final bool stale;

  /// False when we sent nothing usable — the page then shows the plain
  /// chronological list and asks for the reader's situation instead of
  /// pretending the order means something.
  final bool personalised;

  /// Informational-only notice. Shown, never hidden behind a disclosure.
  final String disclaimer;

  /// Set by the client when the API could not be reached at all.
  final bool offline;

  int countOf(Relevance level) => counts[level.wire] ?? 0;

  List<ScoredNewsItem> where(Relevance level) =>
      items.where((e) => e.relevance.level == level).toList(growable: false);

  factory RelevantNewsFeed.fromJson(Map<String, dynamic> j) => RelevantNewsFeed(
    items: [
      for (final e in (j['items'] as List? ?? const []))
        ScoredNewsItem.fromJson((e as Map).cast<String, dynamic>()),
    ],
    total: (j['total'] as num?)?.toInt() ?? 0,
    counts: {
      for (final entry in (j['counts'] as Map? ?? const {}).entries)
        entry.key as String: (entry.value as num?)?.toInt() ?? 0,
    },
    lastScrapedAt: DateTime.tryParse(j['last_scraped_at'] as String? ?? ''),
    stale: j['stale'] as bool? ?? false,
    personalised: j['personalised'] as bool? ?? false,
    disclaimer: j['disclaimer'] as String? ?? '',
  );
}

/// What we send to be scored. Mirrors `SituationInput` in the backend.
///
/// **Sent per request and never stored server-side** — the backend scores it in
/// memory and drops it with the response. That is a product promise, so this
/// object deliberately has no `toJson` that includes a name, an email or an
/// id: there is nothing here to key a record on even if somebody wanted to.
@immutable
class NewsSituation {
  const NewsSituation({
    this.statusText = '',
    this.goalText = '',
    this.currentNodeId,
    this.goalNodeId,
    this.changeYear,
    this.changeMonth,
    this.country,
  });

  static const empty = NewsSituation();

  final String statusText;
  final String goalText;
  final String? currentNodeId;
  final String? goalNodeId;
  final int? changeYear;
  final int? changeMonth;
  final String? country;

  /// Nothing worth scoring — the page falls back to the chronological list.
  bool get isEmpty =>
      statusText.trim().isEmpty &&
      goalText.trim().isEmpty &&
      currentNodeId == null &&
      goalNodeId == null;

  /// Built from what onboarding already collected, so nobody is asked twice.
  factory NewsSituation.fromOnboarding(OnboardingProfile profile) {
    final situation = profile.situation;
    if (situation == null) return NewsSituation.empty;
    return NewsSituation(
      statusText: situation.statusSummary,
      goalText: situation.goalSummary,
      changeYear: situation.changeYear,
      changeMonth: situation.changeMonth,
    );
  }

  Map<String, dynamic> toJson() => {
    'status_text': statusText,
    'goal_text': goalText,
    if (currentNodeId != null) 'current_node_id': currentNodeId,
    if (goalNodeId != null) 'goal_node_id': goalNodeId,
    if (changeYear != null) 'change_year': changeYear,
    if (changeMonth != null) 'change_month': changeMonth,
    if (country != null) 'country': country,
  };
}

/// Mirrors `NewsFeed` in the backend.
@immutable
class NewsFeed {
  const NewsFeed({
    required this.items,
    required this.total,
    this.lastScrapedAt,
    this.stale = false,
    this.offline = false,
  });

  final List<NewsItem> items;
  final int total;
  final DateTime? lastScrapedAt;

  /// The backend's own judgement that the feed is behind its daily cadence.
  final bool stale;

  /// Set by the client when the API could not be reached at all, so the UI can
  /// distinguish "nothing new" from "we could not check".
  final bool offline;

  static const empty = NewsFeed(items: [], total: 0);

  factory NewsFeed.fromJson(Map<String, dynamic> j) => NewsFeed(
    items: [
      for (final i in (j['items'] as List? ?? const []))
        NewsItem.fromJson((i as Map).cast<String, dynamic>()),
    ],
    total: (j['total'] as num?)?.toInt() ?? 0,
    lastScrapedAt: DateTime.tryParse(j['last_scraped_at'] as String? ?? ''),
    stale: j['stale'] as bool? ?? false,
  );
}

/// Mirrors `SourceInfo` — used by the "show your work" source list.
@immutable
class NewsSource {
  const NewsSource({
    required this.id,
    required this.name,
    required this.url,
    this.relatedNodes = const [],
    this.tags = const [],
    this.lastScrapedAt,
    this.lastError,
    this.itemCount = 0,
  });

  final String id;
  final String name;
  final String url;
  final List<String> relatedNodes;
  final List<String> tags;
  final DateTime? lastScrapedAt;
  final String? lastError;
  final int itemCount;

  bool get isHealthy => lastError == null && lastScrapedAt != null;

  factory NewsSource.fromJson(Map<String, dynamic> j) => NewsSource(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    url: j['url'] as String? ?? '',
    relatedNodes: (j['related_nodes'] as List? ?? const []).cast<String>(),
    tags: (j['tags'] as List? ?? const []).cast<String>(),
    lastScrapedAt: DateTime.tryParse(j['last_scraped_at'] as String? ?? ''),
    lastError: j['last_error'] as String?,
    itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
  );
}

/// One news item with read status for personalized feed. Mirrors `UserNewsItem`.
@immutable
class NewsItemWithReadStatus {
  const NewsItemWithReadStatus({
    required this.item,
    required this.isRead,
    this.personalizedHeadline,
    this.personalizedSummary,
    this.relevance = Relevance.worthKnowing,
  });

  /// Mirrors `summarizer.NOT_RELEVANT_HEADLINE` in the backend — the exact
  /// headline text Claude returns when a document doesn't touch the reader's
  /// stated situation, rather than forcing a connection.
  static const notRelevantHeadline = 'Not directly relevant to your situation';

  final NewsItem item;
  final bool isRead;

  /// Claude-written one-line "what this means for you" headline — or
  /// [notRelevantHeadline] when the document doesn't touch this reader's
  /// situation. Null when not generated (no backend API key, generation
  /// failed, or the article predates this feature) — callers fall back to
  /// `item.title`.
  final String? personalizedHeadline;

  /// The plain-language explanation behind [personalizedHeadline]. Null under
  /// the same conditions — callers fall back to `item.summary`, the raw
  /// scraped text.
  final String? personalizedSummary;

  /// Whether [personalizedHeadline] is present and isn't the "not relevant"
  /// sentinel — i.e. there's an actual personalized insight to show.
  bool get hasRelevantInsight =>
      personalizedHeadline != null &&
      personalizedHeadline!.isNotEmpty &&
      personalizedHeadline != notRelevantHeadline;

  /// Whether Claude has explicitly judged this article as not touching the
  /// reader's situation — distinct from "not generated yet".
  bool get isMarkedNotRelevant => personalizedHeadline == notRelevantHeadline;

  /// `affectsYou` names the reader's own status/form/country; `worthKnowing`
  /// touches where they're headed but not them today. Never `background` —
  /// those never reach a personalized feed at all. Backend field:
  /// `UserNewsArticle.relevance_level`.
  final Relevance relevance;

  /// The backend's `/api/user/news/all` and `/unread` responses return flat
  /// `UserNewsArticle` objects (`article_id`, `title`, `link`, `summary`,
  /// `is_unread`, `personalized_summary`) — mirrors
  /// `UserNewsArticle` in `backend/app/models.py`. There is no nested
  /// `NewsItem` on the wire for this endpoint; the metadata that only a
  /// scraped `NewsItem` carries (source, dates, tags) isn't returned here.
  factory NewsItemWithReadStatus.fromJson(Map<String, dynamic> j) =>
      NewsItemWithReadStatus(
        item: NewsItem(
          id: j['article_id'] as String? ?? '',
          sourceId: '',
          sourceName: '',
          title: j['title'] as String? ?? '',
          url: j['link'] as String? ?? '',
          summary: j['summary'] as String? ?? '',
        ),
        isRead: !(j['is_unread'] as bool? ?? true),
        personalizedHeadline: j['personalized_headline'] as String?,
        personalizedSummary: j['personalized_summary'] as String?,
        relevance: Relevance.parse(j['relevance_level'] as String?),
      );
}

/// Personalized feed for authenticated users with pagination and read status.
@immutable
class PersonalisedNewsFeed {
  const PersonalisedNewsFeed({
    required this.items,
    this.total = 0,
    this.offline = false,
    this.error,
    this.cached = false,
  });

  final List<NewsItemWithReadStatus> items;
  final int total;
  final bool offline;
  final String? error;
  final bool cached;

  /// Backend key is `articles` (`AllNewsFeedResponse` / `UnreadNewsFeedResponse`
  /// in `backend/app/models.py`), not `items`.
  factory PersonalisedNewsFeed.fromJson(Map<String, dynamic> j) =>
      PersonalisedNewsFeed(
        items: [
          for (final item in (j['articles'] as List? ?? const []))
            NewsItemWithReadStatus.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
        ],
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}
