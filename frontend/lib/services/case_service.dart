import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/case_profile.dart';
import 'auth_service.dart';
import 'news_service.dart' show NewsService;

/// Whether the backend's intake reasoner is actually configured.
@immutable
class IntakeCapability {
  const IntakeCapability({
    required this.reachable,
    required this.llmAvailable,
    this.model,
  });

  static const offline = IntakeCapability(
    reachable: false,
    llmAvailable: false,
  );

  /// The service answered at all.
  final bool reachable;

  /// It answered *and* has a reasoning model configured. When false, describing
  /// a situation in free text gets keyword matching, so the UI leads with the
  /// questionnaire instead.
  final bool llmAvailable;

  final String? model;
}

/// The person's place on the map: read it, resolve it, store it.
///
/// Storage is local (`SharedPreferences`), keyed per signed-in user so two
/// accounts on one browser never see each other's case. When
/// `POST /api/case/confirm` lands, [save] posts and this becomes a cache.
class CaseService extends ChangeNotifier {
  CaseService._();
  static final instance = CaseService._();

  /// Same origin as the news feed — one backend, one `--dart-define`.
  static const baseUrl = NewsService.baseUrl;

  static const _keyPrefix = 'lumos.case';
  static const _timeout = Duration(seconds: 45);

  CaseProfile? _profile;
  CaseProfile? get profile => _profile;
  bool get hasProfile => _profile != null;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  String get _storageKey {
    final id = AuthService.instance.session?.userId ?? '';
    return id.isEmpty ? _keyPrefix : '$_keyPrefix.$id';
  }

  /// Restores the stored case. Safe to call repeatedly; only reads once per
  /// signed-in user.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null) {
        _profile = CaseProfile.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // A missing or corrupt case means "not set up yet", which the dashboard
      // already handles.
    }
    notifyListeners();
  }

  Future<void> save(CaseProfile profile) async {
    _profile = profile;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(profile.toJson()));
    } catch (_) {
      // In-memory for this session is still a usable case.
    }
  }

  Future<void> clear() async {
    _profile = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (_) {}
  }

  /// Called on sign-out so the next account starts clean.
  void forget() {
    _profile = null;
    _loaded = false;
    notifyListeners();
  }

  /// Asks the backend whether free-text intake is worth offering.
  Future<IntakeCapability> capability() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/case/intake/status'))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return IntakeCapability.offline;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return IntakeCapability(
        reachable: true,
        llmAvailable: body['llm_available'] as bool? ?? false,
        model: body['model'] as String?,
      );
    } catch (e) {
      debugPrint('intake status unavailable at $baseUrl: $e');
      return IntakeCapability.offline;
    }
  }

  /// Free text in, a proposed placement out.
  ///
  /// Throws [IntakeException] rather than returning a wrong-but-plausible
  /// profile: silently degrading to "no status found" would be indistinguishable
  /// from a genuine "we could not place you", and those need different words.
  Future<CaseProfile> resolveFromText(String text, {String? goal}) async {
    late final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$baseUrl/api/case/intake'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'text': text,
              if (goal != null && goal.trim().isNotEmpty) 'goal': goal.trim(),
            }),
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('intake failed at $baseUrl: $e');
      throw const IntakeException(
        'The intake service is not reachable. You can answer the questions '
        'instead — that runs right here in the app.',
      );
    }

    if (response.statusCode == 429) {
      throw const IntakeException(
        'That is a lot of intake requests in a short time. Wait a few minutes, '
        'or use the questions instead.',
      );
    }
    if (response.statusCode != 200) {
      throw IntakeException(
        'The intake service answered with ${response.statusCode}. Try the '
        'questions instead.',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return CaseProfile.fromJson({...body, 'updated_at': null});
  }
}

class IntakeException implements Exception {
  const IntakeException(this.message);
  final String message;

  @override
  String toString() => message;
}
