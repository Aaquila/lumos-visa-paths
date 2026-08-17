import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/news_item.dart';
import 'auth_service.dart';

/// Reads the scraped policy feed from the backend.
///
/// The backend is optional at runtime: if it is not running, every call returns
/// an `offline` feed rather than throwing, and the UI says so plainly instead of
/// showing a spinner forever or, worse, presenting an empty list as "no news".
///
/// Three endpoint types:
///
///  * [alerts] — the public chronological feed. No body, no token, no
///    situation. This is what somebody who has not told us anything gets.
///  * [relevant] — the same items, scored against the reader's situation and
///    sorted with "affects you" first. The situation travels in the request
///    body **for scoring only**: the backend does not store it, and neither
///    does this class beyond the lifetime of the call.
///  * [getNews] — personalized news for the authenticated user with read
///    status tracking and pagination.
class NewsService {
  NewsService._();
  static final instance = NewsService._();

  /// Points at the local backend by default. Override per environment:
  ///   flutter run --dart-define=API_BASE_URL=https://lumos-api.onrender.com
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static const _timeout = Duration(seconds: 8);

  NewsFeed? _cached;
  DateTime? _cachedAt;
  List<NewsItemWithReadStatus>? _personalisedCached;
  DateTime? _personalisedCachedAt;
  int? _cachedUnreadCount;
  DateTime? _unreadCountCachedAt;

  /// Serves a short-lived cache so moving between screens does not re-hit the
  /// API; the feed only changes once a day.
  static const cacheFor = Duration(minutes: 1);

  /// Short cache for unread count to avoid hammering the backend.
  static const unreadCountCacheFor = Duration(seconds: 30);

  Future<NewsFeed> alerts({
    String? nodeId,
    int limit = 50,
    bool forceRefresh = false,
  }) async {
    final fresh =
        _cachedAt != null && DateTime.now().difference(_cachedAt!) < cacheFor;
    if (!forceRefresh && fresh && nodeId == null && _cached != null) {
      return _cached!;
    }

    final uri = Uri.parse('$baseUrl/api/news/alerts').replace(
      queryParameters: {
        'limit': '$limit',
        // Null-aware entry: the key is dropped entirely when nodeId is null.
        'node': ?nodeId,
      },
    );

    try {
      final response = await http.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        return NewsFeed(items: const [], total: 0, offline: true);
      }
      final feed = NewsFeed.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      if (nodeId == null) {
        _cached = feed;
        _cachedAt = DateTime.now();
      }
      return feed;
    } catch (e) {
      debugPrint('news feed unavailable at $baseUrl: $e');
      return NewsFeed(items: const [], total: 0, offline: true);
    }
  }

  /// The feed scored against [situation], `affects_you` first.
  ///
  /// [situation] is sent in the request body and is **not persisted anywhere**
  /// — not by this client, not by the backend. It is scored in memory and
  /// dropped with the response, which is why it is a parameter here rather
  /// than state on this service. Do not add a cache keyed on it.
  ///
  /// Falls back to an `offline` feed on any failure, exactly like [alerts], so
  /// a page that asks for relevance never ends up worse off than one that did
  /// not.
  Future<RelevantNewsFeed> relevant({
    required NewsSituation situation,
    int limit = 60,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/api/news/relevant',
    ).replace(queryParameters: {'limit': '$limit'});

    try {
      final response = await http
          .post(uri, headers: _headers(), body: jsonEncode(situation.toJson()))
          .timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint('relevance scoring returned ${response.statusCode}');
        return const RelevantNewsFeed(offline: true);
      }
      return RelevantNewsFeed.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('relevance unavailable at $baseUrl: $e');
      return const RelevantNewsFeed(offline: true);
    }
  }

  /// Request headers, with the Google ID token attached when we hold a real
  /// one.
  ///
  /// The backend verifies a presented token properly and rejects a bad one, so
  /// sending a stale token would turn a working page into a 401. Only a live,
  /// non-demo token is attached; without one the endpoint is still served,
  /// because it is genuinely public.
  Map<String, String> _headers() {
    final headers = {'Content-Type': 'application/json'};
    final session = AuthService.instance.session;
    final token = session?.idToken;
    if (session != null &&
        !session.isDemo &&
        session.isValid &&
        token != null &&
        token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<List<NewsSource>> sources() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/news/sources'))
          .timeout(_timeout);
      if (response.statusCode != 200) return const [];
      return [
        for (final s in jsonDecode(response.body) as List)
          NewsSource.fromJson((s as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Triggers a scrape now. The daily job runs on its own; this is the manual
  /// "check again" the PRD keeps as a fallback for the scheduler.
  Future<bool> refresh() async {
    try {
      final response = await http
          .post(Uri.parse('$baseUrl/api/news/refresh'))
          .timeout(const Duration(seconds: 90));
      _cached = null;
      _cachedAt = null;
      _personalisedCached = null;
      _personalisedCachedAt = null;
      _cachedUnreadCount = null;
      _unreadCountCachedAt = null;
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fetches personalized news articles for the authenticated user with
  /// read status tracking.
  ///
  /// Returns articles sorted by read status (unread first), with pagination.
  /// Cache is 1 minute; pull-to-refresh clears it.
  Future<PersonalisedNewsFeed> getNews({
    int limit = 20,
    int offset = 0,
    bool forceRefresh = false,
  }) async {
    // Check cache only for first page
    if (offset == 0 && !forceRefresh) {
      final fresh = _personalisedCachedAt != null &&
          DateTime.now().difference(_personalisedCachedAt!) < cacheFor;
      if (fresh && _personalisedCached != null) {
        return PersonalisedNewsFeed(items: _personalisedCached!, cached: true);
      }
    }

    final uri = Uri.parse('$baseUrl/api/user/news/all').replace(
      queryParameters: {
        'limit': '$limit',
        'offset': '$offset',
      },
    );

    try {
      final response = await http
          .get(uri, headers: _headers())
          .timeout(_timeout);

      if (response.statusCode == 401) {
        return PersonalisedNewsFeed(
          items: const [],
          error: 'Please sign in again',
          offline: false,
        );
      }

      if (response.statusCode != 200) {
        return PersonalisedNewsFeed(items: const [], offline: true);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      // Backend key is `articles` (`AllNewsFeedResponse` in
      // backend/app/models.py), not `items`.
      final items = [
        for (final item in (data['articles'] as List? ?? const []))
          NewsItemWithReadStatus.fromJson(
            (item as Map).cast<String, dynamic>(),
          ),
      ];

      // Cache first page results
      if (offset == 0) {
        _personalisedCached = items;
        _personalisedCachedAt = DateTime.now();
      }

      return PersonalisedNewsFeed(
        items: items,
        total: (data['total'] as num?)?.toInt() ?? 0,
        cached: false,
      );
    } catch (e) {
      debugPrint('personalized news unavailable at $baseUrl: $e');
      return PersonalisedNewsFeed(items: const [], offline: true);
    }
  }

  /// Marks an article as read for the authenticated user.
  ///
  /// Returns true on success (200), false on failure.
  Future<bool> markArticleAsRead(String articleId) async {
    final uri = Uri.parse('$baseUrl/api/user/news/$articleId/read');

    try {
      final response = await http
          .post(uri, headers: _headers())
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('failed to mark article as read: $e');
      return false;
    }
  }

  /// Gets the count of unread articles for the authenticated user.
  ///
  /// Used for the dashboard unread badge. Returns 0 on failure or when not
  /// authenticated. Caches the result for 30 seconds to avoid hammering the
  /// backend.
  Future<int> getUnreadCount() async {
    final session = AuthService.instance.session;

    // No auth token - return 0 without making a request
    if (session == null || session.isDemo || !session.isValid) {
      return 0;
    }

    // Check cache
    final cached = _cachedUnreadCount;
    final now = DateTime.now();
    if (cached != null &&
        _unreadCountCachedAt != null &&
        now.difference(_unreadCountCachedAt!) < unreadCountCacheFor) {
      return cached;
    }

    final uri = Uri.parse('$baseUrl/api/user/news/unread/count');

    try {
      final response = await http
          .get(uri, headers: _headers())
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final count = (data['count'] as num?)?.toInt() ?? 0;
        _cachedUnreadCount = count;
        _unreadCountCachedAt = DateTime.now();
        return count;
      }
      // Network error or non-200 response - return 0 silently
      return 0;
    } catch (e) {
      debugPrint('failed to get unread count: $e');
      return 0;
    }
  }
}
