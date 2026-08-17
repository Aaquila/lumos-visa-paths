import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../services/voice_input_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// How a transcript meets what is already in the field.
enum VoiceInsertMode {
  /// Add to what is there. The default, because the field usually already
  /// holds either the person's typing or something onboarding carried over,
  /// and silently wiping it would be the rudest thing this control could do.
  append,

  /// Replace the contents outright.
  replace,
}

/// A microphone that attaches to a text field.
///
/// The reasoning behind the shape of it:
///
///  * **Tap to start, tap to stop.** Not press-and-hold. Holding a button
///    steady while composing a sentence is a real barrier for anyone with a
///    tremor, a motor difference, or an attention that wanders — and this app's
///    users are, by definition, people already carrying a heavy load.
///  * **No clock.** Silence does not end the session (see [VoiceInputService]),
///    nothing counts down, and stopping is always one obvious tap away.
///  * **The words are yours.** The transcript lands in the field as ordinary
///    editable text. Nothing is auto-submitted, nothing is "corrected", and the
///    interim guess is shown while it is still a guess so there are no
///    surprises when it settles.
///  * **Voice is additive.** If the browser cannot do speech recognition the
///    widget renders nothing at all — an absent control, not a broken one — and
///    typing is untouched either way.
class VoiceInputButton extends StatefulWidget {
  const VoiceInputButton({
    super.key,
    required this.controller,
    required this.fieldLabel,
    this.mode = VoiceInsertMode.append,
    this.locale = 'en-US',
    this.service,
    this.showDisclosure = true,
    this.enabled = true,
  });

  /// The field the words go into.
  final TextEditingController controller;

  /// What the field is, in plain words, for screen-reader labels and the
  /// status line: "your situation", "your goal".
  final String fieldLabel;

  final VoiceInsertMode mode;

  /// BCP-47 tag handed to the browser, e.g. `en-US`.
  final String locale;

  /// Injectable for tests. When null the widget owns its own service and
  /// disposes it.
  final VoiceInputService? service;

  /// The one-line note about where the audio goes. On by default; only turn it
  /// off where the same sentence is already on screen next to another mic.
  final bool showDisclosure;

  /// Set false while the surrounding form is busy.
  final bool enabled;

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton>
    with SingleTickerProviderStateMixin {
  late final VoiceInputService _service = widget.service ?? VoiceInputService();
  late final bool _ownsService = widget.service == null;

  late final AnimationController _breath;

  StreamSubscription<VoiceState>? _subscription;
  VoiceState _state = VoiceState.idle;
  String _interim = '';

  @override
  void initState() {
    super.initState();
    // Eagerly, not lazily: an unsupported browser never builds the button, and
    // a controller first touched from dispose() would be created against a
    // dead element.
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _state = _service.state;
    if (_service.isSupported) {
      _subscription = _service.states.listen(_onState);
    }
  }

  @override
  void dispose() {
    // Navigating away mid-sentence must not leave a microphone open.
    unawaited(_subscription?.cancel());
    _breath.dispose();
    if (_ownsService) {
      _service.dispose();
    } else {
      _service.cancel();
    }
    super.dispose();
  }

  void _onState(VoiceState state) {
    if (!mounted) return;
    setState(() {
      _state = state;
      if (state != VoiceState.listening) _interim = '';
    });

    if (state == VoiceState.listening) {
      _breath.repeat(reverse: true);
      _announce(
        'Listening. Take your time — a pause won\'t stop it. Tap the '
        'microphone again when you\'re done.',
      );
    } else {
      _breath.stop();
      _breath.value = 0;
      switch (state) {
        case VoiceState.idle:
          _announce(
            'Stopped listening. Your words are in the ${widget.fieldLabel} '
            'box, and you can edit them.',
          );
        case VoiceState.error:
          final message = _service.lastError?.message;
          if (message != null) _announce(message);
        case VoiceState.listening:
        case VoiceState.processing:
          break;
      }
    }
  }

  /// Speaks a state change to assistive tech.
  ///
  /// The visual states — the pill turning blue, the interim text appearing —
  /// carry no information for a screen-reader user, so each one is announced in
  /// the same plain words the sighted UI uses.
  void _announce(String message) {
    if (!mounted) return;
    if (!MediaQuery.supportsAnnounceOf(context)) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _toggle() async {
    if (_state == VoiceState.listening || _state == VoiceState.processing) {
      _service.stop();
      return;
    }
    setState(() => _interim = '');
    await _service.start(
      locale: widget.locale,
      onPartial: (text) {
        if (!mounted) return;
        setState(() => _interim = text);
      },
      onFinal: _commit,
    );
  }

  /// Puts a settled phrase into the field, as text the person can immediately
  /// edit. The caret is left at the end so typing carries on where the speaking
  /// left off.
  void _commit(String transcript) {
    if (!mounted) return;
    final controller = widget.controller;
    final next = switch (widget.mode) {
      VoiceInsertMode.append => appendTranscript(controller.text, transcript),
      VoiceInsertMode.replace => transcript.trim(),
    };
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    setState(() => _interim = '');
  }

  void _abort() {
    _service.cancel();
    setState(() => _interim = '');
    _announce('Voice input cancelled. Nothing was changed.');
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The whole point of the fallback: no speech recognition, no control.
    if (!_service.isSupported) return const SizedBox.shrink();

    final listening = _state == VoiceState.listening;
    final processing = _state == VoiceState.processing;
    final error = _state == VoiceState.error ? _service.lastError : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _micButton(listening: listening, processing: processing),
            if (listening || processing)
              _TextAction(
                label: 'Cancel',
                onPressed: _abort,
                semanticLabel:
                    'Cancel voice input for ${widget.fieldLabel} and '
                    'discard what has not been added yet',
              ),
            Semantics(
              liveRegion: true,
              child: Text(_statusLine(listening, processing), style: _status),
            ),
          ],
        ),
        if (listening && _interim.trim().isNotEmpty) ...[
          const SizedBox(height: T.s8),
          _InterimPreview(text: _interim),
        ],
        if (error != null) ...[
          const SizedBox(height: T.s8),
          _Line(
            icon: Icons.info_outline,
            text: error.message,
            semanticPrefix: 'Voice input problem. ',
          ),
        ],
        if (widget.showDisclosure) ...[
          const SizedBox(height: T.s8),
          const _Line(icon: Icons.lock_outline, text: voiceDisclosure),
        ],
      ],
    );
  }

  TextStyle get _status => AppTheme.caption;

  String _statusLine(bool listening, bool processing) {
    if (processing) return 'Finishing up…';
    if (listening) return 'Listening — pause as long as you like.';
    if (_state == VoiceState.error) return 'Voice input stopped.';
    return 'Or say it out loud instead of typing.';
  }

  Widget _micButton({required bool listening, required bool processing}) {
    final active = listening || processing;
    final enabled = widget.enabled && !processing;

    final label = active
        ? 'Stop voice input for ${widget.fieldLabel}'
        : 'Use your voice instead of typing for ${widget.fieldLabel}';

    return Semantics(
      button: true,
      enabled: enabled,
      // The label itself carries the on/off state ("Use your voice…" vs "Stop
      // voice input…"), which reads better than a toggled flag on a control
      // whose two states are different actions.
      label: label,
      hint: active
          ? 'Your words are being added to the box as you speak.'
          : 'Tap to start, tap again to stop. You can always type instead.',
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: Material(
            color: Colors.transparent,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? _toggle : null,
              child: AnimatedBuilder(
                animation: _breath,
                builder: (context, child) {
                  // A slow, shallow breath rather than a pulse: enough to say
                  // "this is live", not enough to pull at the eye of somebody
                  // trying to concentrate. Honours the OS reduce-motion setting.
                  final calm = MediaQuery.disableAnimationsOf(context);
                  final glow = listening && !calm
                      ? 0.10 + 0.10 * _breath.value
                      : (listening ? 0.16 : 0.0);
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: T.s16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: listening
                          ? T.signalBlue.withValues(alpha: 0.08 + glow)
                          : T.paper,
                      borderRadius: BorderRadius.circular(T.rPill),
                      border: Border.all(
                        color: listening ? T.signalBlue : T.pencilGray,
                        width: listening ? 1.5 : 1,
                      ),
                    ),
                    child: child,
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      active ? Icons.stop_circle_outlined : Icons.mic_none,
                      size: 18,
                      color: active ? T.signalBlue : T.carbon,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      processing
                          ? 'Finishing…'
                          : (listening ? 'Stop' : 'Speak'),
                      style: AppTheme.label.copyWith(
                        color: active ? T.signalBlue : T.carbon,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The disclosure, in one line, at the point of use.
///
/// The app promises publicly that it collects no personal data and stores no
/// documents, and that promise has to survive contact with a microphone. The
/// honest detail is that the Web Speech API is the *browser's*, and in Chrome
/// it transcribes by sending audio to Google — so that is said plainly, next to
/// the button, before anyone presses it. What Lumos does with the audio is
/// nothing: it never receives it, never keeps it, and the transcript goes no
/// further than the text box on screen.
const String voiceDisclosure =
    'Your browser does the transcribing, not us — in Chrome that means the '
    'audio goes to Google\'s speech service. Lumos never records, stores or '
    'uploads it, and your words go nowhere but the box above.';

/// Shows the running guess while it is still a guess.
///
/// Interim text is visibly provisional — italic, muted, labelled — so that when
/// the browser revises it nobody feels their words were changed behind their
/// back.
class _InterimPreview extends StatelessWidget {
  const _InterimPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Hearing: $text',
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(T.s8),
          decoration: BoxDecoration(
            color: T.pastelSky.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(T.rInput),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.graphic_eq, size: 14, color: T.graphite),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: AppTheme.bodySm.copyWith(
                    fontStyle: FontStyle.italic,
                    color: T.graphite,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.text,
    this.semanticPrefix = '',
  });

  final IconData icon;
  final String text;
  final String semanticPrefix;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$semanticPrefix$text',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 13, color: T.pencilGray),
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: AppTheme.caption)),
          ],
        ),
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.label,
    required this.onPressed,
    required this.semanticLabel,
  });

  final String label;
  final VoidCallback onPressed;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: T.graphite,
            padding: const EdgeInsets.symmetric(horizontal: T.s8),
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(label, style: AppTheme.caption),
        ),
      ),
    );
  }
}
