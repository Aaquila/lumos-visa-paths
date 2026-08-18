import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../models/deadline.dart';
import 'auth_service.dart';
import 'deadline_service.dart';
import 'voice_input_service.dart';

/// Where "Talk to Lumos" is right now.
enum AssistantState {
  idle,
  recording,
  transcribing,
  thinking,
  speaking,
  error,
}

/// One line of the on-screen transcript.
class AssistantTurn {
  const AssistantTurn({required this.fromPerson, required this.text});

  final bool fromPerson;
  final String text;
}

/// What changed on the deadline list as a result of one turn, so the panel
/// can show "Added: Renew passport" with an Undo.
class AssistantChange {
  const AssistantChange({required this.summary, this.undo});

  final String summary;
  final Future<void> Function()? undo;
}

/// "Talk to Lumos" — a voice assistant distinct from the field dictation
/// buttons, but built on the exact same speech recognizer
/// ([VoiceInputService], the browser's Web Speech API). Transcription is
/// local to the browser, same privacy shape as the dictation buttons and same
/// reliability trade-offs (Chrome/Edge only, see `speech_recognizer_web.dart`)
/// — ElevenLabs speech-to-text turned out to be the weak link in practice, so
/// for now only the *reasoning* (Claude) and the *reply voice* (ElevenLabs
/// text-to-speech) are a server round-trip. `POST /api/voice/transcribe`
/// still exists on the backend if that trade gets revisited.
///
/// Nothing here is persisted server-side. The case and deadline snapshot sent
/// with each turn is exactly what [DeadlineService] and onboarding already
/// hold on this device — see the no-persistence note on
/// `POST /api/voice/assistant` in `backend/app/main.py`. The conversation
/// history lives only in [_history], in memory, for this session.
class VoiceAssistantService extends ChangeNotifier {
  VoiceAssistantService({VoiceInputService? speech})
    : _speech = speech ?? VoiceInputService();

  static String get baseUrl {
    final host = dotenv.env['BACKEND_HOST'] ?? '127.0.0.1';
    final port = dotenv.env['BACKEND_PORT'] ?? '8000';
    return 'http://$host:$port';
  }

  static const _timeout = Duration(seconds: 45);

  /// Only the last few turns travel with each request — enough for "no, the
  /// other one" to make sense, not a growing transcript.
  static const _maxHistory = 8;

  final VoiceInputService _speech;

  AssistantState _state = AssistantState.idle;
  AssistantState get state => _state;

  bool get isSupported => _speech.isSupported;

  String? _lastError;
  String? get lastError => _lastError;

  /// The running guess while [state] is [AssistantState.recording], same as
  /// the dictation widget's interim preview.
  String _interim = '';
  String get interim => _interim;

  final List<AssistantTurn> _transcript = [];
  List<AssistantTurn> get transcript => List.unmodifiable(_transcript);

  final List<_HistoryTurn> _history = [];

  AssistantChange? _lastChange;
  AssistantChange? get lastChange => _lastChange;

  JSObject? _player;

  String _spoken = '';

  void _setState(AssistantState next) {
    _state = next;
    notifyListeners();
  }

  // ── Session ────────────────────────────────────────────────────────────────

  Future<void> startListening() async {
    if (_state == AssistantState.recording) return;
    _lastError = null;
    _lastChange = null;
    _spoken = '';
    _interim = '';

    final ok = await _speech.start(
      onPartial: (text) {
        _interim = text;
        notifyListeners();
      },
      onFinal: (text) {
        _spoken = appendTranscript(_spoken, text);
      },
    );
    if (!ok) {
      _lastError =
          _speech.lastError?.message ?? 'Could not open the microphone.';
      _setState(AssistantState.error);
      return;
    }
    _setState(AssistantState.recording);
  }

  /// Stops listening and runs the rest of the pipeline: reason over whatever
  /// was heard, apply any proposed deadline changes, speak the reply.
  Future<void> stopAndAsk() async {
    if (_state != AssistantState.recording) return;

    // The recognizer may still be settling its last phrase after `stop()` —
    // wait for it to actually reach idle/error before reading `_spoken`,
    // rather than racing it.
    _setState(AssistantState.transcribing);
    final done = Completer<void>();
    late final StreamSubscription<VoiceState> sub;
    sub = _speech.states.listen((voiceState) {
      if (voiceState == VoiceState.idle || voiceState == VoiceState.error) {
        if (!done.isCompleted) done.complete();
      }
    });
    _speech.stop();
    await done.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {},
    );
    await sub.cancel();

    _interim = '';
    final transcript = _spoken.trim();
    if (transcript.isEmpty) {
      _lastError =
          _speech.lastError?.message ??
          'I didn\'t catch anything. Try again when you\'re ready.';
      _setState(AssistantState.error);
      return;
    }
    _transcript.add(AssistantTurn(fromPerson: true, text: transcript));
    notifyListeners();

    _setState(AssistantState.thinking);
    await _reason(transcript, speakReply: true);
  }

  /// A typed turn: same reasoning pipeline as speech, minus the recording and
  /// transcription steps. Lets the panel work as an ordinary chat as well as
  /// a voice one — the assistant does not care which way a turn arrived.
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_state == AssistantState.recording) return;

    _lastError = null;
    _lastChange = null;
    _transcript.add(AssistantTurn(fromPerson: true, text: trimmed));
    _setState(AssistantState.thinking);

    // Typed replies stay silent by default — a spoken reply to something
    // that was typed would be the surprising direction, not the expected one.
    await _reason(trimmed, speakReply: false);
  }

  /// Shared tail of both entry points: ask, apply any proposed deadline
  /// changes, optionally speak the reply.
  Future<void> _reason(String transcript, {required bool speakReply}) async {
    final Map<String, dynamic> reply;
    try {
      reply = await _ask(transcript);
    } catch (e) {
      _lastError = 'The assistant isn\'t reachable right now. Try again shortly.';
      _setState(AssistantState.error);
      return;
    }

    final replyText = reply['reply_text'] as String? ?? '';
    final actions = (reply['actions'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

    _history.add(_HistoryTurn(role: 'user', text: transcript));
    _history.add(_HistoryTurn(role: 'assistant', text: replyText));
    while (_history.length > _maxHistory) {
      _history.removeAt(0);
    }

    if (replyText.isNotEmpty) {
      _transcript.add(AssistantTurn(fromPerson: false, text: replyText));
    }
    if (actions.isNotEmpty) {
      _lastChange = await _applyActions(actions);
    }
    notifyListeners();

    if (!speakReply || replyText.trim().isEmpty) {
      _setState(AssistantState.idle);
      return;
    }

    _setState(AssistantState.speaking);
    try {
      await _speak(replyText);
    } catch (_) {
      // Losing the audio reply is not losing the answer — it is already in
      // the on-screen transcript above.
    }
    _setState(AssistantState.idle);
  }

  void cancel() {
    _speech.cancel();
    _interim = '';
    if (_state != AssistantState.idle) _setState(AssistantState.idle);
  }

  void clearError() {
    if (_state == AssistantState.error) {
      _lastError = null;
      _setState(AssistantState.idle);
    }
  }

  @override
  void dispose() {
    _speech.dispose();
    super.dispose();
  }

  // ── Backend calls ─────────────────────────────────────────────────────────

  Map<String, String> _authHeaders() => AuthService.instance.authHeaders;

  Future<Map<String, dynamic>> _ask(String transcript) async {
    final situation = AuthService.instance.onboarding.situation;
    final deadlines = DeadlineService.instance.visible(
      situation: situation,
      profile: null,
      graph: null,
      now: DateTime.now(),
    );

    final payload = {
      'transcript': transcript,
      'history': [
        for (final turn in _history) {'role': turn.role, 'text': turn.text},
      ],
      'case': {
        'current_status_text': situation?.statusText ?? '',
        'goal_text': situation?.goalText ?? '',
      },
      'deadlines': [for (final d in deadlines) _deadlineContext(d)],
    };

    final response = await http
        .post(
          Uri.parse('$baseUrl/api/voice/assistant'),
          headers: {'Content-Type': 'application/json', ..._authHeaders()},
          body: jsonEncode(payload),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException('assistant returned ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Map<String, dynamic> _deadlineContext(Deadline d) => {
    'id': d.id,
    'title': d.title,
    'description': d.description,
    'due_date': d.dueDate?.toIso8601String().substring(0, 10),
    'is_approximate': d.isApproximate,
    'severity': d.severity.wire,
    'source': d.source.wire,
  };

  Future<void> _speak(String text) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/voice/speak'),
          headers: {'Content-Type': 'application/json', ..._authHeaders()},
          body: jsonEncode({'text': text}),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException('speak returned ${response.statusCode}');
    }
    _play(response.bodyBytes);
  }

  // ── Applying proposed actions ────────────────────────────────────────────

  Future<AssistantChange?> _applyActions(
    List<Map<String, dynamic>> actions,
  ) async {
    AssistantChange? last;
    for (final action in actions) {
      final applied = await _applyOne(action);
      if (applied != null) last = applied;
    }
    return last;
  }

  Future<AssistantChange?> _applyOne(Map<String, dynamic> action) async {
    final kind = action['kind'] as String?;
    final service = DeadlineService.instance;

    switch (kind) {
      case 'add_deadline':
        final title = (action['title'] as String? ?? '').trim();
        if (title.isEmpty) return null;
        final dueDate = DateTime.tryParse(
          (action['due_date'] as String?) ?? '',
        );
        final deadline = DeadlineService.compose(
          title: title,
          now: DateTime.now(),
          description: action['description'] as String? ?? '',
          dueDate: dueDate,
          isApproximate: action['is_approximate'] as bool? ?? false,
          nextAction: action['next_action'] as String? ?? '',
        );
        await service.add(deadline);
        return AssistantChange(
          summary: 'Added: $title',
          undo: () => service.remove(deadline.id),
        );

      case 'dismiss_deadline':
        final id = action['target_id'] as String?;
        if (id == null) return null;
        await service.dismiss(id);
        return AssistantChange(
          summary: 'Hid a deadline',
          undo: () => service.restore(id),
        );

      case 'restore_deadline':
        final id = action['target_id'] as String?;
        if (id == null) return null;
        await service.restore(id);
        return AssistantChange(summary: 'Brought a deadline back');

      case 'snooze_deadline':
        final id = action['target_id'] as String?;
        final until = DateTime.tryParse((action['until'] as String?) ?? '');
        if (id == null || until == null) return null;
        await service.snooze(id, until);
        return AssistantChange(
          summary: 'Snoozed until ${until.year}-${until.month}-${until.day}',
          undo: () => service.restore(id),
        );
    }
    return null;
  }

  // ── Playback ─────────────────────────────────────────────────────────────

  /// Plays MP3 bytes via a plain `HTMLAudioElement` over a blob URL. No new
  /// pubspec dependency, matching the style already used for speech
  /// recognition and recording — see `speech_recognizer_web.dart`.
  void _play(Uint8List bytes) {
    try {
      final blobParts = [bytes.toJS].toJS;
      final blobCtor = globalContext.getProperty<JSFunction>('Blob'.toJS);
      final blob = blobCtor.callAsConstructor<JSObject>(
        blobParts,
        {'type': 'audio/mpeg'}.jsify(),
      );
      final urlCtor = globalContext.getProperty<JSObject>('URL'.toJS);
      final url = urlCtor
          .callMethod<JSString>('createObjectURL'.toJS, blob)
          .toDart;

      final audioCtor = globalContext.getProperty<JSFunction>('Audio'.toJS);
      final audio = audioCtor.callAsConstructor<JSObject>(url.toJS);
      audio.setProperty(
        'onended'.toJS,
        ((JSObject _) {
          urlCtor.callMethod<JSAny?>('revokeObjectURL'.toJS, url.toJS);
        }).toJS,
      );
      _player = audio;
      audio.callMethod<JSAny?>('play'.toJS);
    } catch (e) {
      debugPrint('voice assistant playback failed: $e');
    }
  }

  void stopSpeaking() {
    final player = _player;
    if (player == null) return;
    try {
      player.callMethod<JSAny?>('pause'.toJS);
    } catch (_) {
      // Nothing to do.
    }
  }
}

class _HistoryTurn {
  const _HistoryTurn({required this.role, required this.text});
  final String role;
  final String text;
}
