import 'package:flutter/material.dart';

import '../services/voice_assistant_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Opens "Talk to Lumos" as a modal sheet.
///
/// A fresh [VoiceAssistantService] per open: closing the sheet drops the
/// in-memory conversation history along with it, which is the point — nothing
/// here is meant to outlive the conversation, on the device or off it.
Future<void> showVoiceAssistantSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _VoiceAssistantSheet(),
  );
}

class _VoiceAssistantSheet extends StatefulWidget {
  const _VoiceAssistantSheet();

  @override
  State<_VoiceAssistantSheet> createState() => _VoiceAssistantSheetState();
}

class _VoiceAssistantSheetState extends State<_VoiceAssistantSheet> {
  late final VoiceAssistantService _service = VoiceAssistantService();
  final _scroll = ScrollController();
  int _lastTurnCount = 0;

  @override
  void dispose() {
    _scroll.dispose();
    _service.dispose();
    super.dispose();
  }

  void _scrollToEndIfGrown() {
    if (_service.transcript.length == _lastTurnCount) return;
    _lastTurnCount = _service.transcript.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        _scrollToEndIfGrown();
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: mediaQuery.size.height * 0.85,
              ),
              decoration: const BoxDecoration(
                color: T.paper,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(T.rInput * 2),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(T.s24, T.s16, T.s24, T.s16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: T.s16),
                      decoration: BoxDecoration(
                        color: T.pencilGray,
                        borderRadius: BorderRadius.circular(T.rPill),
                      ),
                    ),
                  ),
                  Text('Talk to Lumos', style: AppTheme.headingSm),
                  const SizedBox(height: T.s8),
                  const _Disclosure(),
                  const SizedBox(height: T.s16),
                  Flexible(
                    child: _Transcript(
                      turns: _service.transcript,
                      scrollController: _scroll,
                    ),
                  ),
                  const SizedBox(height: T.s8),
                  if (_service.lastChange != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: T.s8),
                      child: _ChangeChip(
                        change: _service.lastChange!,
                        onUndo: () => setState(() {}),
                      ),
                    ),
                  if (_service.lastError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: T.s8),
                      child: _Line(_service.lastError!),
                    ),
                  if (!_service.isSupported)
                    const Padding(
                      padding: EdgeInsets.only(bottom: T.s8),
                      child: _Line(
                        'This browser can\'t record audio — you can still '
                        'type below.',
                      ),
                    ),
                  _Composer(service: _service),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Disclosure extends StatelessWidget {
  const _Disclosure();

  @override
  Widget build(BuildContext context) {
    return const _Line(
      'This is different from the microphone on the forms: talking to Lumos '
      'sends your voice to ElevenLabs to transcribe and your words to Claude '
      'to answer. Nothing is stored after you close this panel. Lumos may '
      'propose changes to your deadlines, which you can undo right here.',
      icon: Icons.info_outline,
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text, {this.icon = Icons.lock_outline});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 13, color: T.pencilGray),
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: AppTheme.caption)),
      ],
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.turns, required this.scrollController});

  final List<AssistantTurn> turns;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    if (turns.isEmpty) {
      return const _Line(
        'Speak or type to ask about a deadline, or tell Lumos about one to '
        'add.',
        icon: Icons.graphic_eq,
      );
    }
    return ListView.builder(
      controller: scrollController,
      shrinkWrap: true,
      itemCount: turns.length,
      itemBuilder: (context, i) {
        final turn = turns[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: T.s8),
          child: Align(
            alignment: turn.fromPerson
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.symmetric(
                horizontal: T.s16,
                vertical: T.s8,
              ),
              decoration: BoxDecoration(
                color: turn.fromPerson
                    ? T.pastelSky.withValues(alpha: 0.5)
                    : T.paper,
                border: turn.fromPerson
                    ? null
                    : Border.all(color: T.pencilGray),
                borderRadius: BorderRadius.circular(T.rInput),
              ),
              child: Text(turn.text, style: AppTheme.bodySm),
            ),
          ),
        );
      },
    );
  }
}

class _ChangeChip extends StatefulWidget {
  const _ChangeChip({required this.change, required this.onUndo});

  final AssistantChange change;
  final VoidCallback onUndo;

  @override
  State<_ChangeChip> createState() => _ChangeChipState();
}

class _ChangeChipState extends State<_ChangeChip> {
  bool _undone = false;

  @override
  Widget build(BuildContext context) {
    if (_undone) return const SizedBox.shrink();
    final undo = widget.change.undo;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s16, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.pastelSky.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(T.rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 14, color: T.graphite),
          const SizedBox(width: 6),
          Text(widget.change.summary, style: AppTheme.caption),
          if (undo != null) ...[
            const SizedBox(width: T.s8),
            GestureDetector(
              onTap: () async {
                await undo();
                if (mounted) setState(() => _undone = true);
                widget.onUndo();
              },
              child: Text(
                'Undo',
                style: AppTheme.caption.copyWith(
                  color: T.signalBlue,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The bottom row: type a message, or tap the mic to speak one.
///
/// One button does double duty, WhatsApp-style — it shows a mic when the
/// field is empty and a send arrow once there is text to send, so there is
/// never a moment with two ways to submit the same turn.
class _Composer extends StatefulWidget {
  const _Composer({required this.service});

  final VoiceAssistantService service;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    widget.service.sendText(text);
  }

  Future<void> _toggleMic() async {
    final service = widget.service;
    if (service.state == AssistantState.recording) {
      await service.stopAndAsk();
    } else if (service.state == AssistantState.idle ||
        service.state == AssistantState.error) {
      service.clearError();
      await service.startListening();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.service.state;
    final recording = state == AssistantState.recording;
    final busy =
        state == AssistantState.transcribing ||
        state == AssistantState.thinking ||
        state == AssistantState.speaking;
    final hasText = _controller.text.trim().isNotEmpty;
    final fieldEnabled = !recording && !busy;

    final hint = switch (state) {
      AssistantState.recording => widget.service.interim.isEmpty
          ? 'Listening…'
          : widget.service.interim,
      AssistantState.transcribing => 'Finishing up…',
      AssistantState.thinking => 'Thinking…',
      AssistantState.speaking => 'Speaking…',
      _ => 'Type a message, or tap the mic',
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: T.s16),
            decoration: BoxDecoration(
              color: fieldEnabled ? T.paper : const Color(0xFFF5F7F9),
              border: Border.all(
                color: recording ? T.signalBlue : T.pencilGray,
                width: recording ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(T.rPill),
            ),
            alignment: Alignment.centerLeft,
            child: TextField(
              controller: _controller,
              enabled: fieldEnabled,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              style: AppTheme.bodySm,
              decoration: InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
                hintText: hint,
                hintStyle: AppTheme.bodySm.copyWith(
                  color: recording ? T.graphite : T.pencilGray,
                  fontStyle: recording && widget.service.interim.isNotEmpty
                      ? FontStyle.italic
                      : FontStyle.normal,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: T.s8),
        _ActionButton(
          hasText: hasText,
          recording: recording,
          busy: busy,
          supported: widget.service.isSupported,
          onSend: _send,
          onMic: _toggleMic,
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.hasText,
    required this.recording,
    required this.busy,
    required this.supported,
    required this.onSend,
    required this.onMic,
  });

  final bool hasText;
  final bool recording;
  final bool busy;
  final bool supported;
  final VoidCallback onSend;
  final Future<void> Function() onMic;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color, VoidCallback? onTap, String label) =
        switch (true) {
          _ when busy => (
            Icons.more_horiz,
            T.pencilGray,
            null,
            'Thinking',
          ),
          _ when recording => (
            Icons.stop_circle_outlined,
            T.signalBlue,
            onMic,
            'Stop and send',
          ),
          _ when hasText => (
            Icons.arrow_upward,
            T.signalBlue,
            onSend,
            'Send',
          ),
          _ when supported => (
            Icons.mic_none,
            T.carbon,
            onMic,
            'Speak',
          ),
          _ => (Icons.mic_off_outlined, T.pencilGray, null, 'Voice unavailable'),
        };

    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: recording ? T.signalBlue.withValues(alpha: 0.12) : T.paper,
        shape: const CircleBorder(side: BorderSide(color: T.pencilGray)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 20, color: color),
          ),
        ),
      ),
    );
  }
}
