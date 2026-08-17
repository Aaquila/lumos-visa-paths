/// Picks the speech recognizer for whatever we are compiled for.
///
/// On the web that is the browser's own `SpeechRecognition`; everywhere else
/// (including `flutter test`, which runs on the Dart VM) it is the do-nothing
/// [UnsupportedSpeechRecognizer], so nothing in the app has to know which one
/// it got — it just checks `isSupported`.
library;

export 'voice_types.dart';
export 'speech_recognizer_stub.dart'
    if (dart.library.js_interop) 'speech_recognizer_web.dart';
