import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/pathway_graph.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/site_footer.dart';
import 'pathway_style.dart';

/// Everything the graph knows about one status, plus the routes in and out of
/// it. Tapping a route jumps the map to the other end.
class NodeDetailPanel extends StatelessWidget {
  const NodeDetailPanel({
    super.key,
    required this.graph,
    required this.node,
    required this.onClose,
    required this.onGoTo,
  });

  final PathwayGraph graph;
  final PathwayNode node;
  final VoidCallback onClose;
  final ValueChanged<String> onGoTo;

  @override
  Widget build(BuildContext context) {
    final style = CategoryStyle.of(node.categoryId);
    final outgoing = graph.edgesFrom(node.id);
    final incoming = graph.edgesTo(node.id);
    final loops = graph.selfLoops(node.id);

    return Semantics(
      // The panel is a distinct region: naming it means a screen reader
      // announces the move out of the map and into the detail, instead of
      // silently continuing through a wall of new text.
      explicitChildNodes: true,
      label: 'Details for ${node.name}',
      child: Container(
        decoration: const BoxDecoration(
          color: T.paper,
          border: Border(left: BorderSide(color: T.pencilGray)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(T.s24, T.s24, T.s16, T.s16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PastelIconBadge(icon: style.icon, fill: style.fill, size: 34),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: MergeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              graph.category(node.categoryId)?.label ??
                                  node.categoryId,
                              style: AppTheme.caption,
                            ),
                            const SizedBox(height: 2),
                            Text(node.name, style: AppTheme.headingSm),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Icon-only control: the tooltip is what supplies its
                  // accessible name, and "Close" alone would be ambiguous on a
                  // page with several dismissible things. Autofocused so opening
                  // the panel with the keyboard lands you inside it.
                  IconButton(
                    onPressed: onClose,
                    tooltip: 'Close ${node.name} details',
                    autofocus: true,
                    icon: const Icon(Icons.close, size: 18, color: T.graphite),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(T.s24, T.s24, T.s24, T.s40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        MetaPill(
                          label: phaseLabel(node.phase),
                          icon: node.isModeled
                              ? Icons.check_circle_outline
                              : Icons.hourglass_empty,
                          iconColor: node.isModeled
                              ? T.signalBlue
                              : T.pencilGray,
                        ),
                        MetaPill(label: node.id, icon: Icons.tag),
                      ],
                    ),
                    const SizedBox(height: T.s24),
                    Text(node.description, style: AppTheme.body),
                    if (node.requirements.isNotEmpty) ...[
                      const SizedBox(height: T.s24),
                      _SectionLabel('What this route requires'),
                      const SizedBox(height: T.s8),
                      for (final r in node.requirements)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 3),
                                child: Icon(
                                  Icons.check_circle_outline,
                                  size: 13,
                                  color: T.signalBlue,
                                ),
                              ),
                              const SizedBox(width: T.s8),
                              Expanded(child: Text(r, style: AppTheme.bodySm)),
                            ],
                          ),
                        ),
                    ],
                    const SizedBox(height: T.s24),
                    _Field(
                      label: 'Work authorisation',
                      value: node.workAuthorized,
                      icon: Icons.badge_outlined,
                    ),
                    _Field(
                      label: 'Dual intent',
                      value: node.dualIntent,
                      icon: Icons.swap_vert,
                    ),
                    if (node.keyForms.isNotEmpty) ...[
                      const SizedBox(height: T.s8),
                      _SectionLabel('Key forms'),
                      const SizedBox(height: T.s8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final form in node.keyForms)
                            MetaPill(
                              label: form,
                              icon: Icons.description_outlined,
                              iconColor: T.pencilGray,
                            ),
                        ],
                      ),
                    ],
                    if (node.recurringDeadlines.isNotEmpty) ...[
                      const SizedBox(height: T.s24),
                      _SectionLabel('Deadlines this status implies'),
                      const SizedBox(height: T.s8),
                      for (final d in node.recurringDeadlines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 3),
                                child: Icon(
                                  Icons.schedule,
                                  size: 13,
                                  color: T.pencilGray,
                                ),
                              ),
                              const SizedBox(width: T.s8),
                              Expanded(child: Text(d, style: AppTheme.bodySm)),
                            ],
                          ),
                        ),
                    ],
                    if (loops.isNotEmpty) ...[
                      const SizedBox(height: T.s24),
                      _SectionLabel('Stays in this status'),
                      const SizedBox(height: T.s8),
                      for (final e in loops)
                        _RouteTile(
                          title: edgeTypeLabel(e.type),
                          trigger: e.trigger,
                          icon: Icons.loop,
                          onTap: null,
                        ),
                    ],
                    if (outgoing.isNotEmpty) ...[
                      const SizedBox(height: T.s24),
                      _SectionLabel('Routes out (${outgoing.length})'),
                      const SizedBox(height: T.s8),
                      for (final e in outgoing)
                        _RouteTile(
                          title: graph.node(e.to)?.name ?? e.to,
                          subtitle: edgeTypeLabel(e.type),
                          trigger: e.trigger,
                          note: e.note,
                          optional: e.optional,
                          icon: Icons.arrow_forward,
                          onTap: () => onGoTo(e.to),
                        ),
                    ],
                    if (incoming.isNotEmpty) ...[
                      const SizedBox(height: T.s24),
                      _SectionLabel('Routes in (${incoming.length})'),
                      const SizedBox(height: T.s8),
                      for (final e in incoming)
                        _RouteTile(
                          title: graph.node(e.from)?.name ?? e.from,
                          subtitle: edgeTypeLabel(e.type),
                          trigger: e.trigger,
                          note: e.note,
                          optional: e.optional,
                          icon: Icons.arrow_back,
                          onTap: () => onGoTo(e.from),
                        ),
                    ],
                    if (node.sourceHints.isNotEmpty) ...[
                      const SizedBox(height: T.s24),
                      _SectionLabel('Official sources'),
                      const SizedBox(height: T.s8),
                      for (final src in node.sourceHints) _SourceRow(url: src),
                    ],
                    const SizedBox(height: T.s24),
                    const LegalDisclaimer(compact: true),
                    const SizedBox(height: T.s16),
                    PillButton(
                      label: 'Ask the agent',
                      icon: Icons.auto_awesome,
                      // Wired once `POST /api/chat` exists — see
                      // backend/docs/API_ENDPOINTS.md.
                      onPressed: () =>
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              behavior: SnackBarBehavior.floating,
                              backgroundColor: T.ink,
                              content: Text(
                                'Grounded explainer arrives with the agent '
                                'backend — this button already carries '
                                '"${node.name}" as context.',
                                style: AppTheme.bodySm.copyWith(color: T.paper),
                              ),
                            ),
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  // Marked as a heading so a screen reader can jump section to section through
  // the panel instead of reading it top to bottom. Graphite rather than Pencil
  // Gray: 11px uppercase is small text and needs 4.5:1.
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(
      text.toUpperCase(),
      style: AppTheme.badge.copyWith(color: T.graphite, letterSpacing: 0.6),
    ),
  );
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: T.s16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 14, color: T.pencilGray),
          ),
          const SizedBox(width: T.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTheme.caption),
                const SizedBox(height: 2),
                Text(
                  value.isEmpty ? '—' : value,
                  style: AppTheme.bodySm.copyWith(color: T.ink),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteTile extends StatefulWidget {
  const _RouteTile({
    required this.title,
    required this.trigger,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.note,
    this.optional = false,
  });

  final String title;
  final String? subtitle;
  final String trigger;
  final String? note;

  /// Marks a route that skips a step people often assume is mandatory.
  final bool optional;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<_RouteTile> createState() => _RouteTileState();
}

class _RouteTileState extends State<_RouteTile> {
  bool _hover = false;
  bool _focused = false;

  /// Everything the tile shows, as one sentence — a route tile read out as
  /// four disconnected fragments ("H-1B", "· Petition", the trigger, a note)
  /// is much harder to follow than the visual grouping it replaces.
  String get _label => [
    widget.title,
    if (widget.subtitle != null) widget.subtitle!,
    widget.trigger,
    if (widget.optional) 'Optional, can be skipped',
    if (widget.note != null) widget.note!,
  ].join('. ');

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;

    return Semantics(
      button: interactive,
      label: _label,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        enabled: interactive,
        mouseCursor: interactive
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: ExcludeSemantics(
          child: GestureDetector(
            // Semantics are declared by the Semantics wrapper above this
            // control; without this the detector emits a second, unlabelled
            // tappable node beside it.
            excludeFromSemantics: true,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: Motion.duration(
                context,
                const Duration(milliseconds: 140),
              ),
              margin: const EdgeInsets.only(bottom: T.s8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _hover && widget.onTap != null
                    ? const Color(0xFFF5F9FF)
                    : T.paper,
                border: Border.all(
                  color: (_hover || _focused) && widget.onTap != null
                      ? T.signalBlue
                      : T.pencilGray,
                ),
                borderRadius: BorderRadius.circular(T.rInput),
                boxShadow: _focused ? focusRing() : null,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    widget.icon,
                    size: 14,
                    color: _hover && widget.onTap != null
                        ? T.signalBlue
                        : T.pencilGray,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.title,
                                style: AppTheme.bodySm.copyWith(
                                  color: T.ink,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (widget.subtitle != null) ...[
                              const SizedBox(width: 6),
                              Text(
                                '· ${widget.subtitle}',
                                style: AppTheme.caption,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(widget.trigger, style: AppTheme.caption),
                        if (widget.optional) ...[
                          const SizedBox(height: 6),
                          const MetaPill(
                            label: 'Optional — can be skipped',
                            icon: Icons.alt_route,
                          ),
                        ],
                        if (widget.note != null) ...[
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.info_outline,
                                  size: 11,
                                  color: T.pencilGray,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  widget.note!,
                                  style: AppTheme.caption.copyWith(
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.link, size: 13, color: T.signalBlue),
          ),
          const SizedBox(width: T.s8),
          Expanded(
            child: SelectableText(
              url,
              style: AppTheme.caption.copyWith(color: T.signalBlue),
            ),
          ),
          IconButton(
            iconSize: 13,
            visualDensity: VisualDensity.compact,
            // Several of these stack up in one panel, so "Copy link" on its own
            // would give a screen reader a column of identical buttons.
            tooltip: 'Copy $url',
            onPressed: () => Clipboard.setData(ClipboardData(text: url)),
            icon: const Icon(Icons.copy, color: T.graphite),
          ),
        ],
      ),
    );
  }
}
