import 'voice_types.dart';

/// Non-web builds and the VM test runner: there is no browser speech API here,
/// so voice is simply absent and every caller degrades to typing.
SpeechRecognizer createSpeechRecognizer() =>
    const UnsupportedSpeechRecognizer();
