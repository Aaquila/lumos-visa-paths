import 'package:flutter/material.dart';

import '../../models/pathway_graph.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'pathway_style.dart';

/// A single status on the map — a small white "sitemap node card": title row,
/// colour-coded category chip, footer meta.
///
/// The card is the only part of the graph a screen reader or a keyboard can
/// reach: the edges between cards are painted on a canvas and are exposed
/// instead as the "routes in / routes out" counts inside [semanticLabel], and
/// in full in the detail panel and the list view.
class NodeCard extends StatefulWidget {
  const NodeCard({
    super.key,
    required this.node,
    required this.categoryLabel,
    required this.selected,
    required this.dimmed,
    required this.onTap,
    required this.onHover,
    this.focusNode,
    this.semanticLabel,
    this.onFocusChange,
  });

  final PathwayNode node;
  final String categoryLabel;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  /// Supplied by the page so it can drive Tab and arrow-key traversal across
  /// the whole graph from one place.
  final FocusNode? focusNode;

  /// The spoken description of this status, including its relationship to
  /// whatever is currently selected. Falls back to the visible name.
  final String? semanticLabel;

  final ValueChanged<bool>? onFocusChange;

  @override
  State<NodeCard> createState() => _NodeCardState();
}

class _NodeCardState extends State<NodeCard> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final style = CategoryStyle.of(widget.node.categoryId);
    final active = widget.selected || _hover || _focused;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel ?? widget.node.name,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) {
          setState(() => _hover = v);
          widget.onHover(v);
        },
        onFocusChange: (v) {
          setState(() => _focused = v);
          widget.onFocusChange?.call(v);
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          // Semantics are declared by the Semantics wrapper above this
          // control; without this the detector emits a second, unlabelled
          // tappable node beside it.
          excludeFromSemantics: true,
          onTap: widget.onTap,
          child: ExcludeSemantics(
            child: AnimatedOpacity(
              duration: Motion.duration(
                context,
                const Duration(milliseconds: 200),
              ),
              // A dimmed card is still a real target; never fade it so far that
              // its own text drops below contrast.
              opacity: widget.dimmed ? 0.34 : 1,
              child: AnimatedContainer(
                duration: Motion.duration(
                  context,
                  const Duration(milliseconds: 160),
                ),
                width: PathwayGraph.nodeWidth,
                height: PathwayGraph.nodeHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: T.paper,
                  border: Border.all(
                    color: active ? T.signalBlue : T.pencilGray,
                    width: active ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(T.rInput),
                  // Keyboard focus gets a heavier, unmistakable Ink ring on top
                  // of the blue border, so "focused" never looks like merely
                  // "hovered" — a keyboard user has no pointer to confirm with.
                  boxShadow: _focused
                      ? const [
                          BoxShadow(
                            color: T.ink,
                            spreadRadius: 3,
                            blurRadius: 0,
                          ),
                        ]
                      : (active ? T.floatShadow : null),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: style.fill,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(style.icon, size: 13, color: T.ink),
                        ),
                        const SizedBox(width: T.s8),
                        Expanded(
                          child: Text(
                            widget.categoryLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.caption.copyWith(fontSize: 10),
                          ),
                        ),
                        if (widget.node.childIds.isNotEmpty)
                          Tooltip(
                            message: '${widget.node.childIds.length} sub-steps',
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                color: T.signalBlue.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${widget.node.childIds.length}',
                                style: AppTheme.caption.copyWith(
                                  fontSize: 9,
                                  color: T.signalBlue,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        if (!widget.node.isModeled)
                          Tooltip(
                            message: phaseLabel(widget.node.phase),
                            child: const Icon(
                              Icons.hourglass_empty,
                              size: 12,
                              color: T.pencilGray,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: T.s8),
                    Expanded(
                      child: Text(
                        widget.node.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.bodySm.copyWith(
                          color: T.ink,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        if (widget.node.recurringDeadlines.isNotEmpty) ...[
                          const Icon(
                            Icons.schedule,
                            size: 11,
                            color: T.pencilGray,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${widget.node.recurringDeadlines.length}',
                            style: AppTheme.caption.copyWith(fontSize: 10),
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (widget.node.keyForms.isNotEmpty) ...[
                          const Icon(
                            Icons.description_outlined,
                            size: 11,
                            color: T.pencilGray,
                          ),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              widget.node.keyForms.first,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.caption.copyWith(fontSize: 10),
                            ),
                          ),
                        ],
                      ],
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
