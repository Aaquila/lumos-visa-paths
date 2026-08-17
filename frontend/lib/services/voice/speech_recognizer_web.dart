import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'voice_types.dart';

/// The browser's own speech recognition, reached through `dart:js_interop`.
///
/// Deliberately no package: the Web Speech API is a plain global constructor,
/// so a handful of extension types gets us there with no new dependency, no API
/// key, and no server of ours in the audio path. Chrome/Edge expose it as
/// `webkitSpeechRecognition`, the spec name is `SpeechRecognition`, and Firefox
/// exposes neither — which is why every entry point here starts by asking
/// whether it exists at all.
///
/// Privacy note that the UI repeats out loud: in Chrome the audio is sent to
/// Google's speech service for transcription. That happens inside the browser,
/// not through us. We never touch the audio, never keep it, and the transcript
/// goes nowhere but the text field the person is looking at.
SpeechRecognizer createSpeechRecognizer() {
  final ctor = _recognitionConstructor();
  return ctor == null
      ? const UnsupportedSpeechRecognizer()
      : WebSpeechRecognizer(ctor);
}

/// `SpeechRecognition` if the browser has it, `webkitSpeechRecognition` if it
/// only has the prefixed one, null if it has neither.
JSFunction? _recognitionConstructor() {
  for (final name in const ['SpeechRecognition', 'webkitSpeechRecognition']) {
    final found = globalContext.getProperty<JSAny?>(name.toJS);
    if (found.isA<JSFunction>()) return found! as JSFunction;
  }
  return null;
}

// ── Minimal typed views of the JS objects we touch ───────────────────────────

extension type _RecognitionEvent._(JSObject _) implements JSObject {
  external int get resultIndex;
  external _ResultList get results;
}

extension type _ResultList._(JSObject _) implements JSObject {
  external int get length;
  external _Result item(int index);
}

extension type _Result._(JSObject _) implements JSObject {
  external bool get isFinal;
  external _Alternative item(int index);
}

extension type _Alternative._(JSObject _) implements JSObject {
  external String get transcript;
}

extension type _ErrorEvent._(JSObject _) implements JSObject {
  external String? get error;
}

/// Speech recognition backed by the live browser API.
class WebSpeechRecognizer implements SpeechRecognizer {
  WebSpeechRecognizer(this._ctor);

  final JSFunction _ctor;

  JSObject? _recognition;
  bool _running = false;
  bool _disposed = false;

  @override
  bool get isSupported => !_disposed;

  // ── Permission ─────────────────────────────────────────────────────────────

  /// Reads the Permissions API without prompting.
  ///
  /// Several browsers either lack `navigator.permissions` or reject the
  /// `microphone` name outright; both mean "we cannot know yet", not "no", so
  /// they answer [VoicePermission.unknown] and let the real request decide.
  @override
  Future<VoicePermission> permission() async {
    final permissions = globalContext.getProperty<JSAny?>('navigator'.toJS);
    if (!permissions.isA<JSObject>()) return VoicePermission.unknown;
    final navigator = permissions! as JSObject;
    final api = navigator.getProperty<JSAny?>('permissions'.toJS);
    if (!api.isA<JSObject>()) return VoicePermission.unknown;

    try {
      final query = (api! as JSObject).callMethod<JSPromise<JSObject>>(
        'query'.toJS,
        {'name': 'microphone'}.jsify(),
      );
      final status = await query.toDart;
      return switch (status.getProperty<JSString?>('state'.toJS)?.toDart) {
        'granted' => VoicePermission.granted,
        'denied' => VoicePermission.denied,
        'prompt' => VoicePermission.prompt,
        _ => VoicePermission.unknown,
      };
    } catch (_) {
      return VoicePermission.unknown;
    }
  }

  /// Asks for the microphone properly, so the browser prompt appears *before*
  /// the UI claims to be listening rather than during it.
  ///
  /// The stream is released immediately — we only wanted the answer, and
  /// holding an open microphone we are not using would light up the tab's
  /// recording indicator for no reason.
  @override
  Future<VoicePermission> requestPermission() async {
    final navigatorAny = globalContext.getProperty<JSAny?>('navigator'.toJS);
    if (!navigatorAny.isA<JSObject>()) return VoicePermission.unavailable;
    final devices = (navigatorAny! as JSObject).getProperty<JSAny?>(
      'mediaDevices'.toJS,
    );
    if (!devices.isA<JSObject>()) {
      // No getUserMedia (an insecure origin, typically). Speech recognition may
      // still prompt on its own, so don't declare defeat here.
      return VoicePermission.unknown;
    }

    try {
      final stream = await (devices! as JSObject)
          .callMethod<JSPromise<JSObject>>(
            'getUserMedia'.toJS,
            {'audio': true}.jsify(),
          )
          .toDart;
      final tracks = stream.callMethod<JSArray<JSObject>>('getTracks'.toJS);
      for (final track in tracks.toDart) {
        track.callMethod<JSAny?>('stop'.toJS);
      }
      return VoicePermission.granted;
    } catch (error) {
      final text = error.toString();
      if (text.contains('NotFound') || text.contains('NotReadable')) {
        return VoicePermission.unavailable;
      }
      return VoicePermission.denied;
    }
  }

  // ── Session ────────────────────────────────────────────────────────────────

  @override
  void start({
    required String locale,
    required bool continuous,
    required void Function(String) onPartial,
    required void Function(String) onFinal,
    required void Function(VoiceError) onError,
    required void Function() onEnd,
    void Function()? onStart,
  }) {
    if (_disposed) {
      onError(VoiceError.unsupported);
      onEnd();
      return;
    }
    if (_running) return;

    final JSObject recognition;
    try {
      recognition = _ctor.callAsConstructor<JSObject>();
    } catch (error) {
      onError(
        VoiceError(
          VoiceErrorKind.unknown,
          'Voice input could not '
          'start in this browser ($error). Typing works as normal.',
        ),
      );
      onEnd();
      return;
    }

    recognition
      // Keeps the session open across pauses. Without this the browser hangs
      // up the moment somebody stops to think, which is precisely the moment
      // this app's users are most likely to need.
      ..setProperty('continuous'.toJS, continuous.toJS)
      // Interim results are what make the button feel alive rather than broken.
      ..setProperty('interimResults'.toJS, true.toJS)
      ..setProperty('maxAlternatives'.toJS, 1.toJS)
      ..setProperty('lang'.toJS, locale.toJS);

    recognition.setProperty(
      'onstart'.toJS,
      ((JSObject _) {
        _running = true;
        onStart?.call();
      }).toJS,
    );

    recognition.setProperty(
      'onresult'.toJS,
      ((JSObject rawEvent) {
        final event = rawEvent as _RecognitionEvent;
        final results = event.results;
        final interim = StringBuffer();

        // Only the results from this event onwards are new; everything before
        // `resultIndex` has already been delivered.
        for (var i = event.resultIndex; i < results.length; i++) {
          final result = results.item(i);
          final text = result.item(0).transcript;
          if (result.isFinal) {
            if (text.trim().isNotEmpty) onFinal(text);
          } else {
            interim.write(text);
          }
        }
        if (interim.isNotEmpty) onPartial(interim.toString());
      }).toJS,
    );

    recognition.setProperty(
      'onerror'.toJS,
      ((JSObject rawEvent) {
        final code = (rawEvent as _ErrorEvent).error ?? 'unknown';
        onError(VoiceError.fromCode(code));
      }).toJS,
    );

    recognition.setProperty(
      'onend'.toJS,
      ((JSObject _) {
        _running = false;
        onEnd();
      }).toJS,
    );

    _recognition = recognition;
    try {
      recognition.callMethod<JSAny?>('start'.toJS);
      _running = true;
    } catch (error) {
      // InvalidStateError when a previous session has not finished unwinding.
      _running = false;
      onError(VoiceError.fromCode('unknown'));
      onEnd();
    }
  }

  @override
  void stop() {
    final recognition = _recognition;
    if (recognition == null) return;
    try {
      recognition.callMethod<JSAny?>('stop'.toJS);
    } catch (_) {
      // Already stopped. Nothing to do and nothing worth telling anyone.
    }
  }

  @override
  void abort() {
    final recognition = _recognition;
    if (recognition == null) return;
    try {
      recognition.callMethod<JSAny?>('abort'.toJS);
    } catch (_) {
      // Same: aborting something already gone is not a problem.
    }
    _running = false;
  }

  @override
  void dispose() {
    abort();
    final recognition = _recognition;
    if (recognition != null) {
      // Drop the handlers so a late `onend` cannot call back into a widget
      // that has already been torn down.
      for (final handler in const ['onstart', 'onresult', 'onerror', 'onend']) {
        try {
          recognition.setProperty(handler.toJS, null);
        } catch (_) {
          // Best effort.
        }
      }
    }
    _recognition = null;
    _disposed = true;
  }
}
