import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/services/voice_input_service.dart';
import 'package:lumos/widgets/voice_input_button.dart';

/// A stand-in for the browser's speech API.
///
/// Every test in this file drives the state machine through this rather than a
/// real browser: the tests run on the Dart VM, where there is no speech API at
/// all, and the point is to exercise the paths a browser would put us through —
/// including the awkward ones nobody can reproduce on demand, like a permission
/// refusal or Chrome hanging up mid-pause.
class FakeRecognizer implements SpeechRecognizer {
  FakeRecognizer({
    this.supported = true,
    this.permissionResult = VoicePermission.granted,
  });

  final bool supported;
  final VoicePermission permissionResult;

  /// How many times a session has been opened, including automatic reopenings.
  int startCount = 0;
  int stopCount = 0;
  int abortCount = 0;
  int disposeCount = 0;
  bool running = false;
  String? lastLocale;
  bool? lastContinuous;

  void Function(String)? _onPartial;
  void Function(String)? _onFinal;
  void Function(VoiceError)? _onError;
  void Function()? _onEnd;

  @override
  bool get isSupported => supported;

  @override
  Future<VoicePermission> permission() async => permissionResult;

  @override
  Future<VoicePermission> requestPermission() async => permissionResult;

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
    startCount++;
    running = true;
    lastLocale = locale;
    lastContinuous = continuous;
    _onPartial = onPartial;
    _onFinal = onFinal;
    _onError = onError;
    _onEnd = onEnd;
    onStart?.call();
  }

  @override
  void stop() {
    stopCount++;
    if (!running) return;
    running = false;
    _onEnd?.call();
  }

  @override
  void abort() {
    abortCount++;
    running = false;
  }

  @override
  void dispose() => disposeCount++;

  // ── Things a browser would do to us ────────────────────────────────────────

  void emitPartial(String text) => _onPartial?.call(text);
  void emitFinal(String text) => _onFinal?.call(text);
  void emitError(String code) => _onError?.call(VoiceError.fromCode(code));

  /// The browser closing the session by itself — what Chrome does after a few
  /// seconds of silence.
  void emitEnd() {
    running = false;
    _onEnd?.call();
  }
}

/// Pumps a couple of frames.
///
/// Not `pumpAndSettle`: the listening state runs a slow, continuous breathing
/// animation on purpose, so there is nothing to settle to while the microphone
/// is open.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 30));
}

void main() {
  group('VoiceInputService state machine', () {
    test('walks idle → listening → processing → idle', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);
      final seen = <VoiceState>[];
      service.states.listen(seen.add);

      expect(service.state, VoiceState.idle);

      final started = await service.start();
      expect(started, isTrue);
      expect(service.state, VoiceState.listening);
      expect(recognizer.startCount, 1);

      service.stop();
      await Future<void>.delayed(Duration.zero);

      expect(service.state, VoiceState.idle);
      expect(seen, [
        VoiceState.listening,
        VoiceState.processing,
        VoiceState.idle,
      ]);
      service.dispose();
    });

    test('asks the browser for a continuous session', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start(locale: 'en-GB');

      // A session that ends on the first pause would punish anyone who stops
      // to think, which is the whole reason this flag is not optional.
      expect(recognizer.lastContinuous, isTrue);
      expect(recognizer.lastLocale, 'en-GB');
      service.dispose();
    });

    test('a second start while listening is ignored', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      final again = await service.start();

      expect(again, isFalse);
      expect(recognizer.startCount, 1);
      service.dispose();
    });

    test('cancel returns to idle and aborts the session', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      service.cancel();

      expect(service.state, VoiceState.idle);
      expect(recognizer.abortCount, 1);
      service.dispose();
    });

    test('dispose releases the microphone', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      service.dispose();

      expect(recognizer.abortCount, greaterThanOrEqualTo(1));
      expect(recognizer.disposeCount, 1);
    });
  });

  group('pauses are not endings', () {
    test('a no-speech error mid-session is not surfaced as an error', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      recognizer.emitError('no-speech');

      expect(service.state, VoiceState.listening);
      expect(service.lastError, isNull);
      service.dispose();
    });

    test('the session reopens when the browser hangs up on silence', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      recognizer.emitError('no-speech');
      recognizer.emitEnd();

      expect(service.state, VoiceState.listening);
      expect(recognizer.startCount, 2);
      service.dispose();
    });

    test('speech resets the silence budget', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      for (var i = 0; i < 5; i++) {
        recognizer.emitEnd();
      }
      recognizer.emitFinal('I am on an F-1 visa');
      for (var i = 0; i < 5; i++) {
        recognizer.emitEnd();
      }

      // Ten reopenings in total, which is past the cap — but the words in the
      // middle mean somebody is still talking, so it is still listening.
      expect(service.state, VoiceState.listening);
      service.dispose();
    });

    test('endless silence releases the microphone without an error', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      for (var i = 0; i < 12; i++) {
        recognizer.emitEnd();
      }

      expect(service.state, VoiceState.idle);
      expect(service.lastError, isNull);
      service.dispose();
    });
  });

  group('failure paths', () {
    test('an unsupported browser reports unsupported and never starts',
        () async {
      final recognizer = FakeRecognizer(supported: false);
      final service = VoiceInputService(recognizer: recognizer);

      expect(service.isSupported, isFalse);

      final started = await service.start();

      expect(started, isFalse);
      expect(service.state, VoiceState.error);
      expect(service.lastError?.kind, VoiceErrorKind.unsupported);
      expect(recognizer.startCount, 0);
      service.dispose();
    });

    test('a denied microphone errors before listening begins', () async {
      final recognizer = FakeRecognizer(
        permissionResult: VoicePermission.denied,
      );
      final service = VoiceInputService(recognizer: recognizer);

      final started = await service.start();

      expect(started, isFalse);
      expect(service.state, VoiceState.error);
      expect(service.lastError?.kind, VoiceErrorKind.permissionDenied);
      expect(service.permissionStatus, VoicePermission.denied);
      expect(recognizer.startCount, 0);
      // The message has to be usable by someone who does not know what a
      // browser permission is.
      expect(service.lastError!.message, contains('typing'));
      service.dispose();
    });

    test('a permission revoked mid-session stops and reports it', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      recognizer.emitError('not-allowed');

      expect(service.state, VoiceState.error);
      expect(service.lastError?.kind, VoiceErrorKind.permissionDenied);
      expect(service.permissionStatus, VoicePermission.denied);

      // A real fault must not be reopened the way a pause is.
      recognizer.emitEnd();
      expect(recognizer.startCount, 1);
      service.dispose();
    });

    test('a network failure surfaces and does not reopen', () async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      recognizer.emitError('network');
      recognizer.emitEnd();

      expect(service.state, VoiceState.error);
      expect(service.lastError?.kind, VoiceErrorKind.network);
      expect(recognizer.startCount, 1);
      service.dispose();
    });

    test('clearError returns to idle', () async {
      final recognizer = FakeRecognizer(
        permissionResult: VoicePermission.denied,
      );
      final service = VoiceInputService(recognizer: recognizer);

      await service.start();
      service.clearError();

      expect(service.state, VoiceState.idle);
      expect(service.lastError, isNull);
      service.dispose();
    });
  });

  group('appendTranscript', () {
    test('adds to what is already there rather than replacing it', () {
      expect(
        appendTranscript('I am on OPT.', 'It started in June.'),
        'I am on OPT. It started in June.',
      );
    });

    test('fills an empty field without a leading space', () {
      expect(appendTranscript('', 'I am on OPT'), 'I am on OPT');
      expect(appendTranscript('   ', 'I am on OPT'), 'I am on OPT');
    });

    test('does not double a space that is already there', () {
      expect(appendTranscript('I am on OPT ', 'since June'),
          'I am on OPT since June');
      expect(appendTranscript('I am on OPT\n', 'since June'),
          'I am on OPT\nsince June');
    });

    test('an empty transcript leaves the field untouched', () {
      expect(appendTranscript('typed by hand', '   '), 'typed by hand');
    });
  });

  group('VoiceInputButton', () {
    Widget host(VoiceInputService service, TextEditingController controller) {
      return MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(controller: controller),
              VoiceInputButton(
                controller: controller,
                fieldLabel: 'your situation',
                service: service,
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('renders nothing when the browser cannot do speech',
        (tester) async {
      final service = VoiceInputService(
        recognizer: FakeRecognizer(supported: false),
      );
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(service, controller));

      expect(find.byType(VoiceInputButton), findsOneWidget);
      // Present in the tree, but with nothing in it: an absent control rather
      // than a broken one. Typing is untouched.
      expect(find.text('Speak'), findsNothing);
      expect(find.byIcon(Icons.mic_none), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('offers the microphone and the disclosure when supported',
        (tester) async {
      final service = VoiceInputService(recognizer: FakeRecognizer());
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(service, controller));

      expect(find.text('Speak'), findsOneWidget);
      expect(find.text(voiceDisclosure), findsOneWidget);
      // The promise the app makes publicly has to hold at the microphone too.
      expect(voiceDisclosure, contains('never records, stores or uploads'));
    });

    testWidgets('tap starts, transcript lands as editable text, tap stops',
        (tester) async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);
      final controller = TextEditingController(text: 'I finished my MS.');
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(service, controller));

      await tester.tap(find.text('Speak'));
      await settle(tester);
      expect(service.state, VoiceState.listening);
      expect(find.text('Stop'), findsOneWidget);

      recognizer.emitPartial('I am on');
      await tester.pump();
      expect(find.text('I am on'), findsOneWidget);
      // Still a guess, so it has not touched the field yet.
      expect(controller.text, 'I finished my MS.');

      recognizer.emitFinal('I am on OPT.');
      await tester.pump();
      expect(controller.text, 'I finished my MS. I am on OPT.');
      expect(controller.selection.baseOffset, controller.text.length);

      await tester.tap(find.text('Stop'));
      await settle(tester);
      expect(service.state, VoiceState.idle);
      // Nothing was submitted on the way out.
      expect(controller.text, 'I finished my MS. I am on OPT.');
    });

    testWidgets('replace mode overwrites instead of appending', (tester) async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);
      final controller = TextEditingController(text: 'old text');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceInputButton(
              controller: controller,
              fieldLabel: 'your situation',
              mode: VoiceInsertMode.replace,
              service: service,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Speak'));
      await settle(tester);
      recognizer.emitFinal('brand new words');
      await tester.pump();

      expect(controller.text, 'brand new words');
      service.dispose();
    });

    testWidgets('cancel abandons the session without touching the field',
        (tester) async {
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);
      final controller = TextEditingController(text: 'typed by hand');
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(service, controller));

      await tester.tap(find.text('Speak'));
      await settle(tester);
      recognizer.emitPartial('something half said');
      await tester.pump();

      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(service.state, VoiceState.idle);
      expect(controller.text, 'typed by hand');
      expect(find.text('something half said'), findsNothing);
    });

    testWidgets('a denied microphone shows a plain-language message',
        (tester) async {
      final service = VoiceInputService(
        recognizer: FakeRecognizer(permissionResult: VoicePermission.denied),
      );
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(service, controller));

      await tester.tap(find.text('Speak'));
      await settle(tester);

      expect(service.state, VoiceState.error);
      expect(find.textContaining('microphone is blocked'), findsOneWidget);
      // The field is still there and still typeable.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('every control carries a semantics label', (tester) async {
      final handle = tester.ensureSemantics();
      final recognizer = FakeRecognizer();
      final service = VoiceInputService(recognizer: recognizer);
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(service, controller));

      expect(
        find.bySemanticsLabel(
          'Use your voice instead of typing for your situation',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Speak'));
      await settle(tester);

      expect(
        find.bySemanticsLabel('Stop voice input for your situation'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('Cancel voice input')),
        findsOneWidget,
      );

      recognizer.emitPartial('half a sentence');
      await tester.pump();
      expect(
        find.bySemanticsLabel('Hearing: half a sentence'),
        findsOneWidget,
      );

      handle.dispose();
    });

    testWidgets('leaving the screen mid-listen releases the microphone',
        (tester) async {
      final recognizer = FakeRecognizer();
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceInputButton(
              controller: controller,
              fieldLabel: 'your situation',
              service: VoiceInputService(recognizer: recognizer),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Speak'));
      await settle(tester);
      expect(recognizer.running, isTrue);

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));

      expect(recognizer.abortCount, greaterThanOrEqualTo(1));
      expect(recognizer.running, isFalse);
    });
  });
}
