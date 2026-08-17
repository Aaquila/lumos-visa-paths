/// The vocabulary the voice stack speaks in — states, errors, permissions, and
/// the thin platform contract underneath.
///
/// None of this touches the browser, so the state machine in
/// `voice_input_service.dart` and the widget on top of it can both be tested on
/// the Dart VM with a fake [SpeechRecognizer].
library;

/// Where the service is right now.
///
/// Deliberately four states and no more: anything finer would show up in the UI
/// as flicker, and the point of this control is that it is calm.
enum VoiceState {
  /// Not listening. The resting state, and where every error path returns to
  /// once the person has read what went wrong.
  idle,

  /// The microphone is open. A long silence does *not* leave this state — see
  /// the restart handling in `VoiceInputService`.
  listening,

  /// The person asked to stop and the last words are still being resolved.
  processing,

  /// Something went wrong and there is a plain-language message to show.
  error,
}

/// Microphone permission, as far as we can tell.
///
/// [unknown] and [unavailable] are distinct on purpose: "we have not asked yet"
/// is a reason to try, "this browser cannot" is a reason to stop.
enum VoicePermission { granted, denied, prompt, unknown, unavailable }

/// Why voice input stopped working.
enum VoiceErrorKind {
  /// The browser has no speech recognition at all (Firefox, most notably).
  unsupported,

  /// The person said no to the microphone, or the site is not allowed one.
  permissionDenied,

  /// Nothing was heard. Only surfaced when the person is no longer listening —
  /// mid-session this is treated as a thinking pause, not a failure.
  noSpeech,

  /// The transcription service could not be reached.
  network,

  /// There is no usable microphone, or another app has it.
  audioCapture,

  /// The requested language is not one the browser can transcribe.
  languageNotSupported,

  /// We stopped it ourselves. Never shown.
  aborted,

  unknown,
}

/// An error with a sentence that can be put in front of a person as-is.
///
/// The messages avoid blame and avoid jargon: they say what happened and what
/// is still possible, and every one of them ends with the reminder that typing
/// was never taken away.
class VoiceError {
  const VoiceError(this.kind, this.message);

  final VoiceErrorKind kind;
  final String message;

  /// Builds an error from a Web Speech API error code.
  factory VoiceError.fromCode(String code) => switch (code) {
    'not-allowed' || 'service-not-allowed' => const VoiceError(
      VoiceErrorKind.permissionDenied,
      'The microphone is blocked for this site. You can turn it back on in '
      'your browser\'s address bar, or just keep typing — that always '
      'works.',
    ),
    'no-speech' => const VoiceError(
      VoiceErrorKind.noSpeech,
      'I didn\'t catch anything. Take your time and tap the mic again when '
      'you\'re ready.',
    ),
    'audio-capture' => const VoiceError(
      VoiceErrorKind.audioCapture,
      'I couldn\'t find a microphone. Check it\'s plugged in and not in use '
      'by another app. Typing works either way.',
    ),
    'network' => const VoiceError(
      VoiceErrorKind.network,
      'The speech service couldn\'t be reached. Nothing was lost — you can '
      'try again, or type instead.',
    ),
    'language-not-supported' => const VoiceError(
      VoiceErrorKind.languageNotSupported,
      'This browser can\'t transcribe that language. You can still type '
      'anything you like here.',
    ),
    'aborted' => const VoiceError(VoiceErrorKind.aborted, 'Stopped.'),
    _ => VoiceError(
      VoiceErrorKind.unknown,
      'Voice input stopped unexpectedly ($code). Typing works as normal.',
    ),
  };

  static const unsupported = VoiceError(
    VoiceErrorKind.unsupported,
    'This browser doesn\'t do speech recognition.',
  );

  static const permissionDenied = VoiceError(
    VoiceErrorKind.permissionDenied,
    'The microphone is blocked for this site. You can turn it back on in '
    'your browser\'s address bar, or just keep typing — that always works.',
  );

  @override
  String toString() => 'VoiceError(${kind.name}: $message)';
}

/// The one thing that differs between a real browser and a test.
///
/// Implementations are expected to be forgiving: [stop], [abort] and [dispose]
/// must be safe to call at any time, including when nothing is running.
abstract class SpeechRecognizer {
  /// False when the platform has no speech recognition. Everything above this
  /// layer checks it and hides itself rather than failing at the tap.
  bool get isSupported;

  /// The current permission, without prompting anybody.
  Future<VoicePermission> permission();

  /// Asks for the microphone, prompting if the browser wants to.
  Future<VoicePermission> requestPermission();

  /// Opens the microphone.
  ///
  /// [onFinal] fires per settled phrase rather than once at the end, so the
  /// text can land in the field while the person is still talking.
  /// [onEnd] fires whenever the underlying session closes — including the
  /// browser closing it by itself, which is the case the service restarts from.
  void start({
    required String locale,
    required bool continuous,
    required void Function(String transcript) onPartial,
    required void Function(String transcript) onFinal,
    required void Function(VoiceError error) onError,
    required void Function() onEnd,
    void Function()? onStart,
  });

  /// Ends the session, keeping whatever has been recognised so far.
  void stop();

  /// Ends the session and throws away anything pending.
  void abort();

  /// Releases the underlying object. The recognizer is unusable afterwards.
  void dispose();
}

/// The recognizer used when the platform has no speech API.
///
/// It is not an error type — it reports [isSupported] as false and does nothing
/// else, which is exactly what the UI needs to hide the control.
class UnsupportedSpeechRecognizer implements SpeechRecognizer {
  const UnsupportedSpeechRecognizer();

  @override
  bool get isSupported => false;

  @override
  Future<VoicePermission> permission() async => VoicePermission.unavailable;

  @override
  Future<VoicePermission> requestPermission() async =>
      VoicePermission.unavailable;

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
    onError(VoiceError.unsupported);
    onEnd();
  }

  @override
  void stop() {}

  @override
  void abort() {}

  @override
  void dispose() {}
}
