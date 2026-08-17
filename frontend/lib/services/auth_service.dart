import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/onboarding_profile.dart';

@immutable
class UserSession {
  const UserSession({
    required this.displayName,
    required this.email,
    required this.expiresAt,
    this.userId = '',
    this.onboarding = OnboardingProfile.empty,
    this.photoUrl,
    this.idToken,
    this.isDemo = false,
  });

  final String displayName;
  final String email;
  final DateTime expiresAt;

  /// What this person picked on the way in: the name Lumos calls them by, and
  /// the visa situation they described.
  ///
  /// It rides on the session because it is answered once, immediately after
  /// sign-in, and every screen that greets somebody needs it synchronously —
  /// the same reason the session itself is restored before the first frame.
  final OnboardingProfile onboarding;

  /// Google's stable subject id (`sub`). This is the key a backend would use as
  /// `users.google_sub` (PROJECT_PRD §7a).
  final String userId;
  final String? photoUrl;

  /// The Google ID token. Short-lived (~1 hour) and not renewed by the GIS SDK,
  /// so it is only useful immediately after sign-in — to hand to a backend that
  /// verifies it once and issues its own session.
  final String? idToken;

  /// True when running without a configured OAuth client, so the UI can say so
  /// rather than implying a real identity.
  final bool isDemo;

  bool get isValid => DateTime.now().isBefore(expiresAt);

  /// The name Lumos calls this person by: the one they tapped in onboarding,
  /// falling back to the first word of the Google display name until they have.
  ///
  /// Never null, so every greeting has something to say even mid-onboarding.
  String get preferredName {
    final chosen = onboarding.chosenName;
    if (chosen != null && chosen.isNotEmpty) return chosen;
    final first = displayName.trim().split(RegExp(r'\s+')).first;
    return first.isEmpty ? email.split('@').first : first;
  }

  /// The picked name, or null when step 1 has not happened. Nullable on
  /// purpose: "they have not chosen yet" is a state the UI needs to see.
  String? get chosenName => onboarding.chosenName;

  bool get hasChosenName => onboarding.hasName;

  UserSession withOnboarding(OnboardingProfile value) => UserSession(
    displayName: displayName,
    email: email,
    expiresAt: expiresAt,
    userId: userId,
    onboarding: value,
    photoUrl: photoUrl,
    idToken: idToken,
    isDemo: isDemo,
  );

  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) {
      return email.isEmpty ? '?' : email.substring(0, 1).toUpperCase();
    }
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'email': email,
    'expiresAt': expiresAt.toIso8601String(),
    'userId': userId,
    'onboarding': onboarding.toJson(),
    'photoUrl': photoUrl,
    'isDemo': isDemo,
  };

  /// The ID token is deliberately not persisted — it expires within the hour
  /// and storing it buys nothing.
  factory UserSession.fromJson(Map<String, dynamic> j) => UserSession(
    displayName: j['displayName'] as String? ?? '',
    email: j['email'] as String? ?? '',
    expiresAt:
        DateTime.tryParse(j['expiresAt'] as String? ?? '') ?? DateTime(2000),
    userId: j['userId'] as String? ?? '',
    onboarding: j['onboarding'] is Map
        ? OnboardingProfile.fromJson(
            (j['onboarding'] as Map).cast<String, dynamic>(),
          )
        : OnboardingProfile.empty,
    photoUrl: j['photoUrl'] as String?,
    isDemo: j['isDemo'] as bool? ?? false,
  );
}

/// Google-only authentication (PROJECT_PRD §5).
///
/// This is the real Google Identity Services flow, not a stub. Two things are
/// worth knowing about how it behaves on the web:
///
///  * GIS only signs a user in through Google's own rendered button, so the
///    sign-in screen shows that button rather than a custom one. On desktop and
///    mobile targets [signInWithGoogle] works directly.
///  * GIS does not keep a session. It hands back an ID token good for about an
///    hour and forgets you. The "stay signed in for 14 days" behaviour the PRD
///    asks for is therefore an application-level session, persisted here; a
///    backend would upgrade this to a verified JWT + refresh token via
///    `POST /api/auth/google`.
///
/// Configure with:
///   flutter run -d chrome --dart-define=GOOGLE_CLIENT_ID=xxxx.apps.googleusercontent.com
/// With no client id set, [isConfigured] is false and the UI offers a clearly
/// labelled demo session instead, so the rest of the app stays explorable.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final instance = AuthService._();

  static const clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const sessionDuration = Duration(days: 14);
  static const _storageKey = 'lumos.session';

  bool get isConfigured => clientId.isNotEmpty;

  UserSession? _session;
  UserSession? get session => _session;
  bool get isSignedIn => _session != null && _session!.isValid;

  bool _busy = false;
  bool get isBusy => _busy;

  String? _error;
  String? get error => _error;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// Chosen on the sign-in screen before the Google flow starts, then applied
  /// when the account comes back.
  bool staySignedIn = false;

  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;

  /// Called once from `main()`. Restores any stored session, then wires up
  /// Google Identity Services if a client id was supplied at build time.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _restore();

    if (!isConfigured) {
      notifyListeners();
      return;
    }

    try {
      await GoogleSignIn.instance.initialize(clientId: clientId);
      _events = GoogleSignIn.instance.authenticationEvents.listen(
        _onAuthEvent,
        onError: (Object e) => _fail(e),
      );
      // Silently restore a Google session where the platform supports it.
      unawaited(
        Future<void>.sync(
          () => GoogleSignIn.instance.attemptLightweightAuthentication(),
        ).then((_) {}).catchError((Object _) {}),
      );
    } catch (e) {
      _error = 'Google sign-in could not start: $e';
    }
    notifyListeners();
  }

  void _onAuthEvent(GoogleSignInAuthenticationEvent event) {
    switch (event) {
      case GoogleSignInAuthenticationEventSignIn():
        _adopt(event.user);
      case GoogleSignInAuthenticationEventSignOut():
        _session = null;
        unawaited(_clearStored());
        notifyListeners();
    }
  }

  void _adopt(GoogleSignInAccount user) {
    // Onboarding answers belong to the person, not to the token —
    // re-authenticating the same account must not make them start over.
    final previous = _session;
    final sameUser =
        previous != null &&
        (previous.userId == user.id || previous.email == user.email);

    _session = UserSession(
      displayName: user.displayName ?? user.email.split('@').first,
      email: user.email,
      userId: user.id,
      onboarding: sameUser ? previous.onboarding : OnboardingProfile.empty,
      photoUrl: user.photoUrl,
      idToken: user.authentication.idToken,
      expiresAt: DateTime.now().add(
        staySignedIn ? sessionDuration : const Duration(hours: 12),
      ),
    );
    _busy = false;
    _error = null;
    unawaited(_persist());
    notifyListeners();
  }

  void _fail(Object e) {
    _busy = false;
    _error = e is GoogleSignInException
        ? 'Google sign-in failed (${e.code.name}). ${e.description ?? ''}'
              .trim()
        : 'Google sign-in failed: $e';
    notifyListeners();
  }

  /// Direct sign-in, for platforms whose Google SDK provides its own flow.
  ///
  /// On the web this is not supported by design — GIS requires its own rendered
  /// button — so the sign-in screen shows [GoogleSignInButton] instead, which
  /// routes to the same [authenticationEvents] stream.
  Future<bool> signInWithGoogle({bool? rememberMe}) async {
    if (rememberMe != null) staySignedIn = rememberMe;

    if (!isConfigured) {
      _error =
          'No Google client id was configured for this build. '
          'Rebuild with --dart-define=GOOGLE_CLIENT_ID=… or continue as a demo user.';
      notifyListeners();
      return false;
    }
    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      _error = 'Use the Google button to sign in on this platform.';
      notifyListeners();
      return false;
    }

    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final user = await GoogleSignIn.instance.authenticate();
      _adopt(user);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// An explicitly-labelled local session, so the product is explorable without
  /// a Google Cloud project. This never claims to be a real Google identity.
  Future<void> continueAsDemoUser({bool? rememberMe}) async {
    if (rememberMe != null) staySignedIn = rememberMe;
    _session = UserSession(
      displayName: 'Demo Traveller',
      email: 'demo@lumos.app',
      userId: 'demo-user',
      isDemo: true,
      expiresAt: DateTime.now().add(
        staySignedIn ? sessionDuration : const Duration(hours: 12),
      ),
    );
    _error = null;
    await _persist();
    notifyListeners();
  }

  // ── Onboarding ────────────────────────────────────────────────────────────
  //
  // Local to the session and persisted with it. When the user table lands these
  // become `PATCH /api/auth/me` — see `backend/docs/API_ENDPOINTS.md` §1.

  OnboardingProfile get onboarding =>
      _session?.onboarding ?? OnboardingProfile.empty;

  /// Step 1: the name the user tapped. [id] is an id from
  /// [NameChoice.options]; anything else is ignored rather than stored, so the
  /// field can never hold arbitrary text.
  Future<void> chooseName(String id) async {
    final session = _session;
    final choice = NameChoice.byId(id);
    if (session == null || choice == null) return;
    await _updateOnboarding(
      session.onboarding.copyWith(chosenNameId: choice.id),
    );
  }

  /// Re-opens step 1 — the entry point a settings screen would call.
  Future<void> clearChosenName() async {
    final session = _session;
    if (session == null) return;
    await _updateOnboarding(session.onboarding.copyWith(clearName: true));
  }

  /// Step 2, answered. Storing an empty situation is fine and means "they went
  /// through it and had nothing to add" — [OnboardingProfile.situationDone] is
  /// what unblocks the dashboard, not the contents.
  Future<void> saveSituation(VisaSituation situation) async {
    final session = _session;
    if (session == null) return;
    await _updateOnboarding(
      session.onboarding.copyWith(
        situation: situation,
        situationDone: true,
        clearSituation: situation.isEmpty,
      ),
    );
  }

  /// Step 2, part-answered. Keeps what has been typed so far without marking
  /// the step done, so closing the tab mid-question loses nothing.
  Future<void> saveSituationDraft(VisaSituation situation) async {
    final session = _session;
    if (session == null) return;
    await _updateOnboarding(session.onboarding.copyWith(situation: situation));
  }

  /// Step 2, skipped. Nothing is a hard gate.
  Future<void> skipSituation() async {
    final session = _session;
    if (session == null) return;
    await _updateOnboarding(
      session.onboarding.copyWith(situationDone: true, clearSituation: true),
    );
  }

  Future<void> _updateOnboarding(OnboardingProfile next) async {
    final session = _session;
    if (session == null) return;
    _session = session.withOnboarding(next);
    notifyListeners();
    await _persist();
  }

  Future<void> signOut() async {
    _session = null;
    _error = null;
    await _clearStored();
    if (isConfigured) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        // Signing out locally is what matters; the SDK may not have a session.
      }
    }
    notifyListeners();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(session.toJson()));
    } catch (_) {
      // A session that survives only in memory is still a usable session.
    }
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null) return;
      final restored = UserSession.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (restored.isValid) {
        _session = restored;
      } else {
        await prefs.remove(_storageKey);
      }
    } catch (_) {
      // Corrupt or unavailable storage simply means "not signed in".
    }
  }

  Future<void> _clearStored() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (_) {}
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }
}
