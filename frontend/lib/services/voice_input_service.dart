import 'dart:async';

import 'voice/speech_recognizer.dart';

export 'voice/speech_recognizer.dart'
    show
        VoiceError,
        VoiceErrorKind,
        VoicePermission,
        VoiceState,
        SpeechRecognizer,
        UnsupportedSpeechRecognizer;

/// Speech-to-text for the free-text boxes, wrapped in a state machine that is
/// forgiving about silence.
///
/// The browser's speech API is not built for someone who is thinking. Chrome
/// hangs up after roughly eight seconds of quiet — it fires `no-speech` and
/// ends the session — which for this app would mean the microphone switching
/// itself off in the middle of somebody working out how to describe their visa
/// status. So the rule here is: **a pause is not an ending.** While the person
/// still wants to be heard, a session that closes on its own is quietly
/// reopened and the words already transcribed are kept. Only the person's own
/// tap on stop, or a real fault, ends it.
///
/// The counterweight is [_maxSilentRestarts]: if nothing at all is heard across
/// that many reopenings, the microphone is released rather than left running
/// against a tab somebody has walked away from. Any recognised speech resets
/// the count, so a person who is actually talking never hits it.
///
/// Nothing here stores or transmits audio or text. Transcripts are handed to
/// the caller's callbacks and forgotten.
class VoiceInputService {
  VoiceInputService({SpeechRecognizer? recognizer})
    : _recognizer = recognizer ?? createSpeechRecognizer();

  /// Reopenings with no speech at all before we let the microphone go.
  ///
  /// At roughly eight seconds of silence per round this is over a minute of
  /// uninterrupted quiet — long enough to be a real pause, short enough not to
  /// hold a microphone open on an abandoned tab.
  static const _maxSilentRestarts = 8;

  final SpeechRecognizer _recognizer;
  final _states = StreamController<VoiceState>.broadcast();

  VoiceState _state = VoiceState.idle;
  VoiceError? _lastError;
  VoicePermission _permission = VoicePermission.unknown;

  /// The person's intent, as distinct from whether the browser happens to have
  /// a session open right now. This is what makes a pause survivable.
  bool _wantListening = false;
  int _silentRestarts = 0;
  bool _disposed = false;

  String _locale = 'en-US';
  void Function(String)? _onPartial;
  void Function(String)? _onFinal;

  /// False when the platform has no speech recognition. Callers hide their
  /// voice affordances entirely rather than offering a control that cannot work.
  bool get isSupported => _recognizer.isSupported;

  VoiceState get state => _state;

  /// The last failure worth showing a person, or null. Cleared by [start].
  VoiceError? get lastError => _lastError;

  /// Microphone permission as last observed. [VoicePermission.unknown] until
  /// something has actually asked.
  VoicePermission get permissionStatus => _permission;

  /// Idle / listening / processing / error, as it changes.
  Stream<VoiceState> get states => _states.stream;

  bool get isListening => _state == VoiceState.listening;

  // ── Permission ─────────────────────────────────────────────────────────────

  /// Asks the browser for the microphone, prompting the person if needed.
  ///
  /// Safe to call repeatedly; the answer is cached in [permissionStatus].
  Future<VoicePermission> requestPermission() async {
    if (!isSupported) {
      return _permission = VoicePermission.unavailable;
    }
    final result = await _recognizer.requestPermission();
    return _permission = result;
  }

  /// Reads the current permission without prompting.
  Future<VoicePermission> refreshPermission() async {
    if (!isSupported) return _permission = VoicePermission.unavailable;
    return _permission = await _recognizer.permission();
  }

  // ── Session ────────────────────────────────────────────────────────────────

  /// Opens the microphone.
  ///
  /// [onPartial] receives the running guess so the person can see it working;
  /// [onFinal] receives each phrase once the browser has settled on it, phrase
  /// by phrase rather than all at the end, so words land in the field while
  /// they are still talking.
  ///
  /// Returns false if it could not start — check [lastError] for the reason.
  /// It never throws.
  Future<bool> start({
    void Function(String transcript)? onPartial,
    void Function(String transcript)? onFinal,
    String locale = 'en-US',
  }) async {
    if (_disposed) return false;
    if (!isSupported) {
      _fail(VoiceError.unsupported);
      return false;
    }
    if (_state == VoiceState.listening || _state == VoiceState.processing) {
      return false;
    }

    if (_permission != VoicePermission.granted) {
      final permission = await requestPermission();
      if (_disposed) return false;
      if (permission == VoicePermission.denied) {
        _fail(VoiceError.permissionDenied);
        return false;
      }
      if (permission == VoicePermission.unavailable) {
        _fail(
          const VoiceError(
            VoiceErrorKind.audioCapture,
            'I couldn\'t find a microphone to use. Typing works as normal.',
          ),
        );
        return false;
      }
    }

    _onPartial = onPartial;
    _onFinal = onFinal;
    _locale = locale;
    _lastError = null;
    _silentRestarts = 0;
    _wantListening = true;
    _setState(VoiceState.listening);
    _listen();
    return true;
  }

  /// Hands the microphone back, keeping everything transcribed so far.
  void stop() {
    if (!_wantListening && _state != VoiceState.listening) return;
    _wantListening = false;
    if (_state == VoiceState.listening) _setState(VoiceState.processing);
    _recognizer.stop();
  }

  /// Stops and discards anything still in flight — the abort, for when somebody
  /// wants out rather than a result.
  void cancel() {
    _wantListening = false;
    _onPartial = null;
    _onFinal = null;
    _recognizer.abort();
    if (_state != VoiceState.idle) _setState(VoiceState.idle);
  }

  /// Clears a shown error and returns to rest.
  void clearError() {
    if (_state == VoiceState.error) {
      _lastError = null;
      _setState(VoiceState.idle);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _wantListening = false;
    _onPartial = null;
    _onFinal = null;
    _recognizer.abort();
    _recognizer.dispose();
    _states.close();
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  void _listen() {
    _recognizer.start(
      locale: _locale,
      continuous: true,
      onPartial: _handlePartial,
      onFinal: _handleFinal,
      onError: _handleError,
      onEnd: _handleEnd,
    );
  }

  void _handlePartial(String transcript) {
    if (_disposed || !_wantListening) return;
    _onPartial?.call(transcript);
  }

  void _handleFinal(String transcript) {
    if (_disposed) return;
    // Real speech: the silence budget starts over.
    _silentRestarts = 0;
    if (transcript.trim().isEmpty) return;
    _onFinal?.call(transcript);
  }

  void _handleError(VoiceError error) {
    if (_disposed) return;

    // "No speech" during a session the person has not ended is a thinking
    // pause. Swallow it — the reopen in [_handleEnd] carries the session on.
    if (error.kind == VoiceErrorKind.noSpeech && _wantListening) return;

    // We caused this one, so there is nothing to report.
    if (error.kind == VoiceErrorKind.aborted) return;

    if (error.kind == VoiceErrorKind.permissionDenied) {
      _permission = VoicePermission.denied;
    }
    _wantListening = false;
    _fail(error);
  }

  void _handleEnd() {
    if (_disposed) return;

    if (_wantListening) {
      _silentRestarts++;
      if (_silentRestarts <= _maxSilentRestarts) {
        _listen();
        return;
      }
      // Quiet for a long time. Let the microphone go without calling it a
      // failure — the person keeps whatever was already transcribed.
      _wantListening = false;
    }

    if (_state != VoiceState.error) _setState(VoiceState.idle);
  }

  void _fail(VoiceError error) {
    _lastError = error;
    _setState(VoiceState.error);
  }

  void _setState(VoiceState next) {
    if (_disposed || _state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}

/// Joins a new transcript onto whatever is already in the field.
///
/// Spoken text is added to what the person wrote, never over it, and spacing is
/// tidied so the result reads as one sentence rather than a seam. Kept pure and
/// public so the behaviour can be tested without a browser or a widget.
String appendTranscript(String existing, String addition) {
  final incoming = addition.trim();
  if (incoming.isEmpty) return existing;
  if (existing.trim().isEmpty) return incoming;

  final needsSpace = !existing.endsWith(' ') && !existing.endsWith('\n');
  return '$existing${needsSpace ? ' ' : ''}$incoming';
}
