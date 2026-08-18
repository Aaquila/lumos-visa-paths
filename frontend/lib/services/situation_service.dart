import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../models/onboarding_profile.dart';
import 'auth_service.dart';

/// Persists a signed-in user's confirmed situation server-side.
///
/// Everywhere else in this app a situation travels in a request body for
/// scoring only and is dropped with the response (see `NewsService.relevant`
/// and the backend's `SituationInput`). This is the one deliberate exception:
/// `POST /api/user/situation` is what the backend's personalization pass
/// scores against to build `/api/user/news/*`, so it has to be stored
/// *somewhere* for that to work later, unlike a same-request scoring call.
///
/// The backend is optional at runtime, same as [NewsService]: a failed or
/// skipped save never blocks onboarding — the situation is already saved
/// locally by [AuthService.saveSituation] regardless, and this is a
/// best-effort mirror of it, not the source of truth on-device.
class SituationService {
  SituationService._();
  static final instance = SituationService._();

  static String get baseUrl {
    final host = dotenv.env['BACKEND_HOST'] ?? '127.0.0.1';
    final port = dotenv.env['BACKEND_PORT'] ?? '8000';
    return 'http://$host:$port';
  }

  static const _timeout = Duration(seconds: 8);

  /// Saves [situation] to the backend for the signed-in user, if any.
  ///
  /// No-ops (and returns `false`) when signed out, on the demo account, or
  /// with nothing worth saving — the backend requires non-empty status text,
  /// and there is nothing to personalize against for a demo session that
  /// isn't a real, persisted identity.
  Future<bool> save(VisaSituation situation) async {
    if (!situation.hasStatus) return false;

    final session = AuthService.instance.session;
    final token = session?.idToken;
    if (session == null ||
        session.isDemo ||
        !session.isValid ||
        token == null ||
        token.isEmpty) {
      return false;
    }

    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/user/situation'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'status_text': situation.statusSummary,
              'goal_text': situation.goalSummary,
            }),
          )
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('failed to save situation to backend: $e');
      return false;
    }
  }
}
