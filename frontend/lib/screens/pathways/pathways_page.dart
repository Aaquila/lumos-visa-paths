import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:go_router/go_router.dart';

import '../../models/pathway_graph.dart';
import '../../services/pathway_repository.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/site_nav.dart';
import 'edge_painter.dart';
import 'graph_viewport.dart';
import 'node_card.dart';
import 'node_detail_panel.dart';
import 'pathway_style.dart';

// ── Keyboard intents ────────────────────────────────────────────────────────
// Declared as intents driven through Shortcuts/Actions rather than a raw
// RawKeyboardListener so they compose with Flutter's focus system: text fields
// in the header keep their own arrow keys, and the graph only sees a key when
// nothing more specific has claimed it.

/// Walk to the nearest status in [direction] (a unit vector in canvas space).
class _MoveNodeIntent extends Intent {
  const _MoveNodeIntent(this.direction);
  final Offset direction;
}

/// `+` / `-` / `0`. A [factor] of `null` means "fit the whole graph".
class _ZoomIntent extends Intent {
  const _ZoomIntent(this.factor);
  final double? factor;
}

class _ClosePanelIntent extends Intent {
  const _ClosePanelIntent();
}

/// `/visa-pathways` — the full generic graph: every modelled status and every
/// documented transition between them, pannable and zoomable, with a detail
/// panel for whichever status you tap.
///
/// Accessibility contract for this page:
///  * every status is a focusable, labelled button (Tab / Shift+Tab, or the
///    arrow keys for graph-aware movement);
///  * Enter or Space opens its detail panel, Escape closes it and returns
///    focus to where it came from;
///  * `+` / `-` / `0` drive the same zoom API the on-screen buttons use;
///  * a full non-visual equivalent lives behind the map/list toggle.
class PathwaysPage extends StatefulWidget {
  const PathwaysPage({super.key, this.focusNodeId});

  /// Deep link: `/visa-pathways?node=temp_worker.h1b`.
  final String? focusNodeId;

  @override
  State<PathwaysPage> createState() => _PathwaysPageState();
}

class _PathwaysPageState extends State<PathwaysPage> {
  /// Zoom bounds, shared by the viewport, the buttons and "fit to screen".
  static const _minScale = 0.1;
  static const _maxScale = 2.5;

  final _transform = TransformationController();
  final _searchController = TextEditingController();
  final _viewerKey = GlobalKey<GraphViewportState>();

  PathwayGraph? _graph;
  String? _error;

  String? _selectedId;
  String? _hoverId;
  String _query = '';
  final Set<String> _mutedCategories = {};
  bool _onlyModelled = false;

  /// The equivalent non-visual view. A canvas of custom-painted cards and edges
  /// can never be made fully accessible, so the same graph is also offered as a
  /// plain nested list — same data, same actions, no painting.
  bool _listView = false;

  /// One [FocusNode] per status, owned here so arrow-key traversal, Tab order
  /// and "jump to this node" all move the same focus.
  final Map<String, FocusNode> _nodeFocus = {};

  /// Which status currently holds keyboard focus, which is not the same thing
  /// as which one is selected — you can walk the graph without opening panels.
  String? _keyboardId;

  @override
  void initState() {
    super.initState();
    PathwayRepository.instance
        .load()
        .then((graph) {
          if (!mounted) return;
          setState(() {
            _graph = graph;
            _selectedId =
                widget.focusNodeId != null &&
                    graph.node(widget.focusNodeId!) != null
                ? widget.focusNodeId
                : null;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_selectedId != null) {
              _centerOn(_selectedId!);
            } else {
              _fitToViewport();
            }
          });
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  @override
  void dispose() {
    _transform.dispose();
    _searchController.dispose();
    for (final node in _nodeFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _focusFor(String id) => _nodeFocus.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'pathway-node-$id'),
  );

  // ── Viewport helpers ──────────────────────────────────────────────────────

  /// Every viewport move goes through the [GraphViewport] itself so that the
  /// scale bounds and the "don't lose the graph off-screen" clamping are
  /// applied once, in one place, whichever control triggered the move.
  GraphViewportState? get _viewport => _viewerKey.currentState;

  void _fitToViewport() => _viewport?.fit();

  void _centerOn(String nodeId, {double? targetScale}) {
    final pos = _graph?.positions[nodeId];
    if (pos == null) return;
    _viewport?.focusOn(
      Offset(
        pos.x + PathwayGraph.nodeWidth / 2,
        pos.y + PathwayGraph.nodeHeight / 2,
      ),
      targetScale: targetScale ?? _currentScale.clamp(_minScale, 1.1),
    );
  }

  double get _currentScale => _transform.value.getMaxScaleOnAxis();

  void _zoomBy(double factor) => _viewport?.zoomBy(factor);

  // ── Filtering ─────────────────────────────────────────────────────────────

  Set<String> _visibleIds(PathwayGraph graph) {
    final q = _query.trim().toLowerCase();
    return {
      for (final n in graph.nodes)
        if ((_mutedCategories.isEmpty ||
                !_mutedCategories.contains(n.categoryId)) &&
            (!_onlyModelled || n.isModeled) &&
            (q.isEmpty ||
                n.name.toLowerCase().contains(q) ||
                n.id.toLowerCase().contains(q) ||
                n.description.toLowerCase().contains(q) ||
                n.keyForms.any((f) => f.toLowerCase().contains(q))))
          n.id,
    };
  }

  void _select(String? id) {
    setState(() => _selectedId = id);
    if (id != null) _centerOn(id);
  }

  // ── Accessibility ─────────────────────────────────────────────────────────

  /// What a screen reader says when it lands on a status card.
  ///
  /// The edges are painted pixels, so the only way a non-visual user learns
  /// that H-1B connects to EB-2 is if the card says so. This states the name,
  /// the category, whether the family is modelled yet, how many routes run in
  /// and out, and — crucially — how this status relates to whatever is
  /// currently selected, which is the relationship the highlight is drawing
  /// visually.
  String _semanticLabelFor(PathwayGraph graph, PathwayNode node) {
    final parts = <String>[
      node.name,
      graph.category(node.categoryId)?.label ?? node.categoryId,
      phaseLabel(node.phase),
    ];

    final out = graph.edgesFrom(node.id).length;
    final into = graph.edgesTo(node.id).length;
    parts.add(
      '$out ${out == 1 ? 'route' : 'routes'} out, '
      '$into ${into == 1 ? 'route' : 'routes'} in',
    );

    final selected = _selectedId;
    if (selected != null && selected != node.id) {
      final selectedNode = graph.node(selected);
      final name = selectedNode?.name ?? selected;
      final from = graph.edges.any(
        (e) => e.from == selected && e.to == node.id,
      );
      final to = graph.edges.any((e) => e.to == selected && e.from == node.id);
      if (from && to) {
        parts.add('connects both ways with $name');
      } else if (from) {
        parts.add('reachable from $name');
      } else if (to) {
        parts.add('leads to $name');
      } else {
        parts.add('not connected to $name');
      }
    } else if (selected == node.id) {
      parts.add('selected');
    }

    return '${parts.join('. ')}.';
  }

  // ── Keyboard navigation ───────────────────────────────────────────────────

  Offset _centreOf(PathwayGraph graph, String id) {
    final p = graph.positions[id]!;
    return Offset(
      p.x + PathwayGraph.nodeWidth / 2,
      p.y + PathwayGraph.nodeHeight / 2,
    );
  }

  /// Move keyboard focus to the nearest visible status in [direction].
  ///
  /// Nearest is measured along the axis of travel, with movement across the
  /// axis penalised, so pressing → walks the row you are on rather than
  /// wandering diagonally into another family.
  void _moveFocus(PathwayGraph graph, Offset direction) {
    final visible = _visibleIds(graph);
    if (visible.isEmpty) return;

    final currentId = _keyboardId ?? _selectedId;
    if (currentId == null || !visible.contains(currentId)) {
      // No anchor yet: start at the top-left-most status on screen.
      final first = visible.toList()
        ..sort((a, b) {
          final pa = graph.positions[a]!;
          final pb = graph.positions[b]!;
          final byX = pa.x.compareTo(pb.x);
          return byX != 0 ? byX : pa.y.compareTo(pb.y);
        });
      _focusNode(graph, first.first);
      return;
    }

    final origin = _centreOf(graph, currentId);
    String? best;
    var bestCost = double.infinity;

    for (final id in visible) {
      if (id == currentId) continue;
      final delta = _centreOf(graph, id) - origin;
      final along = delta.dx * direction.dx + delta.dy * direction.dy;
      if (along <= 1) continue; // behind us, or level with us
      final across = (delta.dx * direction.dy - delta.dy * direction.dx).abs();
      final cost = along + across * 2.5;
      if (cost < bestCost) {
        bestCost = cost;
        best = id;
      }
    }

    if (best != null) _focusNode(graph, best);
  }

  /// Focus a status and bring it into view, without selecting it — arrowing
  /// around the graph should not keep re-opening the detail panel.
  void _focusNode(PathwayGraph graph, String id) {
    setState(() => _keyboardId = id);
    _focusFor(id).requestFocus();
    _centerOn(id);
  }

  // Enter and Space need no binding here: the default WidgetsApp shortcuts
  // already turn them into an ActivateIntent, which each NodeCard's own
  // FocusableActionDetector handles as "open this status".

  /// Escape closes the detail panel and hands focus back to the status it was
  /// describing, so a keyboard user is not dumped at the top of the page.
  bool _closePanel() {
    if (_selectedId == null) return false;
    final id = _selectedId!;
    setState(() => _selectedId = null);
    _focusFor(id).requestFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);
    final graph = _graph;

    return Scaffold(
      backgroundColor: T.paper,
      body: Column(
        children: [
          const SiteNav(transparent: false, activeRoute: '/visa-pathways'),
          if (graph == null)
            Expanded(
              child: Center(
                child: _error == null
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Text(
                        'Could not load the pathway graph.\n$_error',
                        textAlign: TextAlign.center,
                        style: AppTheme.body,
                      ),
              ),
            )
          else ...[
            _Header(
              graph: graph,
              query: _query,
              controller: _searchController,
              onQuery: (v) => setState(() => _query = v),
              onlyModelled: _onlyModelled,
              onOnlyModelled: (v) => setState(() => _onlyModelled = v),
              mutedCategories: _mutedCategories,
              onToggleCategory: (id) => setState(() {
                _mutedCategories.contains(id)
                    ? _mutedCategories.remove(id)
                    : _mutedCategories.add(id);
              }),
              onFit: _fitToViewport,
              onJump: _select,
              listView: _listView,
              onListView: (v) => setState(() => _listView = v),
            ),
            Expanded(
              // The key bindings wrap the canvas *and* the detail panel, so
              // Escape still closes the panel while focus is inside it — but
              // deliberately not the header, so typing "0" or "-" into the
              // search box types rather than zooming.
              child: _withShortcuts(
                graph,
                child: Focus(
                  // Gives the map region focus on arrival, so the arrow and
                  // zoom keys work before anything has been Tabbed to. Skipped
                  // in Tab order: it is a key sink, not a stop.
                  autofocus: true,
                  skipTraversal: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: _listView
                            ? PathwayListView(
                                graph: graph,
                                visible: _visibleIds(graph),
                                selectedId: _selectedId,
                                onSelect: (id) =>
                                    setState(() => _selectedId = id),
                              )
                            : _buildCanvas(graph, mobile),
                      ),
                      if (!mobile && _selectedId != null)
                        SizedBox(
                          width: 400,
                          child: NodeDetailPanel(
                            graph: graph,
                            node: graph.node(_selectedId!)!,
                            onClose: () => _closePanel(),
                            onGoTo: _select,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Every key binding on this page, in one place.
  ///
  /// Bound at the page level rather than per-card so they still work while
  /// focus is on the zoom buttons or the legend, and so Escape closes the panel
  /// from anywhere.
  Widget _withShortcuts(PathwayGraph graph, {required Widget child}) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): _MoveNodeIntent(
          Offset(-1, 0),
        ),
        SingleActivator(LogicalKeyboardKey.arrowRight): _MoveNodeIntent(
          Offset(1, 0),
        ),
        SingleActivator(LogicalKeyboardKey.arrowUp): _MoveNodeIntent(
          Offset(0, -1),
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown): _MoveNodeIntent(
          Offset(0, 1),
        ),
        // Both the main-row and numpad forms, and `=` because reaching `+`
        // means holding shift on most layouts.
        SingleActivator(LogicalKeyboardKey.equal): _ZoomIntent(1.25),
        SingleActivator(LogicalKeyboardKey.add): _ZoomIntent(1.25),
        SingleActivator(LogicalKeyboardKey.numpadAdd): _ZoomIntent(1.25),
        SingleActivator(LogicalKeyboardKey.minus): _ZoomIntent(0.8),
        SingleActivator(LogicalKeyboardKey.numpadSubtract): _ZoomIntent(0.8),
        SingleActivator(LogicalKeyboardKey.digit0): _ZoomIntent(null),
        SingleActivator(LogicalKeyboardKey.numpad0): _ZoomIntent(null),
        SingleActivator(LogicalKeyboardKey.escape): _ClosePanelIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _MoveNodeIntent: CallbackAction<_MoveNodeIntent>(
            onInvoke: (intent) {
              _moveFocus(graph, intent.direction);
              return null;
            },
          ),
          _ZoomIntent: CallbackAction<_ZoomIntent>(
            onInvoke: (intent) {
              // Routed through GraphViewportState so keyboard zoom shares the
              // clamping and focal maths with the wheel and the buttons.
              intent.factor == null
                  ? _fitToViewport()
                  : _zoomBy(intent.factor!);
              return null;
            },
          ),
          _ClosePanelIntent: CallbackAction<_ClosePanelIntent>(
            onInvoke: (_) {
              _closePanel();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }

  Widget _buildCanvas(PathwayGraph graph, bool mobile) {
    final visible = _visibleIds(graph);
    final focus = _selectedId ?? _hoverId;
    final highlighted = focus == null ? const <String>{} : {focus};

    // The key bindings live one level up, around the canvas and the panel
    // together — see build().
    return Semantics(
      // Names the region and tells a screen-reader user, once, how to drive
      // it — otherwise the keyboard map is undiscoverable.
      label:
          'Visa pathway map, ${visible.length} of ${graph.nodes.length} '
          'statuses shown. Arrow keys move between statuses, Enter opens '
          'one, Escape closes it. A list view is available from the '
          'toolbar.',
      explicitChildNodes: true,
      child: Stack(
        children: [
          // Blueprint dot grid — the "lab notebook" ground the cards sit on.
          Positioned.fill(
            child: ExcludeSemantics(
              child: CustomPaint(painter: _DotGridPainter()),
            ),
          ),
          Positioned.fill(
            child: GraphViewport(
              key: _viewerKey,
              controller: _transform,
              canvasSize: Size(graph.canvasWidth, graph.canvasHeight),
              minScale: _minScale,
              maxScale: _maxScale,
              onInteractionEnd: () => setState(() {}),
              // Tab order follows the layout — left to right, then top to
              // bottom — which is the order the graph is meant to be read in.
              // The default policy would follow declaration order in the Stack.
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Painted edges: no semantics of their own. Their content is
                    // carried by each node's label and by the detail panel.
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: CustomPaint(
                          painter: EdgePainter(
                            graph: graph,
                            visible: visible,
                            highlighted: highlighted,
                            dimmed: focus != null,
                          ),
                        ),
                      ),
                    ),
                    for (final node in graph.nodes)
                      if (visible.contains(node.id))
                        Positioned(
                          left: graph.positions[node.id]!.x,
                          top: graph.positions[node.id]!.y,
                          child: FocusTraversalOrder(
                            order: NumericFocusOrder(
                              graph.positions[node.id]!.x * 10000 +
                                  graph.positions[node.id]!.y,
                            ),
                            child: NodeCard(
                              node: node,
                              categoryLabel:
                                  graph.category(node.categoryId)?.label ??
                                  node.categoryId,
                              selected: _selectedId == node.id,
                              dimmed:
                                  focus != null &&
                                  node.id != focus &&
                                  !_isNeighbour(graph, focus, node.id),
                              focusNode: _focusFor(node.id),
                              semanticLabel: _semanticLabelFor(graph, node),
                              onFocusChange: (focused) {
                                // Tabbing counts as walking the graph, so the
                                // arrow keys pick up from wherever Tab left off.
                                if (focused && _keyboardId != node.id) {
                                  setState(() => _keyboardId = node.id);
                                }
                              },
                              onTap: () => _select(
                                _selectedId == node.id ? null : node.id,
                              ),
                              onHover: (hovering) => setState(
                                () => _hoverId = hovering ? node.id : null,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),

          // Zoom controls.
          Positioned(
            right: T.s16,
            bottom: T.s16,
            child: _ZoomControls(
              scale: _currentScale,
              onZoomIn: () => _zoomBy(1.25),
              onZoomOut: () => _zoomBy(0.8),
              onFit: _fitToViewport,
            ),
          ),

          // Legend.
          if (!mobile)
            Positioned(
              left: T.s16,
              bottom: T.s16,
              child: _Legend(count: visible.length, total: graph.nodes.length),
            ),

          // On narrow screens the detail panel becomes a bottom sheet.
          if (mobile && _selectedId != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: MediaQuery.sizeOf(context).height * 0.55,
              child: Material(
                elevation: 0,
                color: T.paper,
                child: NodeDetailPanel(
                  graph: graph,
                  node: graph.node(_selectedId!)!,
                  onClose: () => _closePanel(),
                  onGoTo: _select,
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _isNeighbour(PathwayGraph graph, String focus, String other) =>
      graph.edges.any(
        (e) =>
            (e.from == focus && e.to == other) ||
            (e.to == focus && e.from == other),
      );
}

// ── Header: title, search, filters ──────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.graph,
    required this.query,
    required this.controller,
    required this.onQuery,
    required this.onlyModelled,
    required this.onOnlyModelled,
    required this.mutedCategories,
    required this.onToggleCategory,
    required this.onFit,
    required this.onJump,
    required this.listView,
    required this.onListView,
  });

  final PathwayGraph graph;
  final String query;
  final TextEditingController controller;
  final ValueChanged<String> onQuery;
  final bool onlyModelled;
  final ValueChanged<bool> onOnlyModelled;
  final Set<String> mutedCategories;
  final ValueChanged<String> onToggleCategory;
  final VoidCallback onFit;
  final ValueChanged<String> onJump;
  final bool listView;
  final ValueChanged<bool> onListView;

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    return Container(
      padding: EdgeInsets.fromLTRB(
        mobile ? T.s16 : T.s32,
        T.s24,
        mobile ? T.s16 : T.s32,
        T.s16,
      ),
      decoration: const BoxDecoration(
        color: T.paper,
        border: Border(bottom: BorderSide(color: T.pencilGray)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('US visa pathways', style: AppTheme.heading(context)),
                    const SizedBox(height: 6),
                    Text(
                      '${graph.nodes.length} statuses · ${graph.edges.length} '
                      'transitions · structural seed as of ${graph.asOf}. '
                      'Every number is re-verified against its official '
                      'source before reaching a person.',
                      style: AppTheme.bodySm,
                    ),
                  ],
                ),
              ),
              if (!mobile) ...[
                const SizedBox(width: T.s24),
                PillButton(
                  label: 'Back to home',
                  icon: Icons.arrow_back,
                  onPressed: () => context.go('/'),
                ),
              ],
            ],
          ),
          const SizedBox(height: T.s16),
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: mobile ? double.infinity : 300,
                child: _SearchField(
                  controller: controller,
                  onChanged: onQuery,
                  graph: graph,
                  onJump: onJump,
                ),
              ),
              _Toggle(
                label: 'Modelled families only',
                value: onlyModelled,
                onChanged: onOnlyModelled,
              ),
              // The accessible equivalent of the canvas. Offered as a peer of
              // the map, not hidden away as an accessibility afterthought —
              // plenty of sighted people prefer to read a list too.
              PillButton(
                label: listView ? 'Show map view' : 'Show list view',
                icon: listView
                    ? Icons.account_tree_outlined
                    : Icons.format_list_bulleted,
                onPressed: () => onListView(!listView),
              ),
              if (!listView)
                PillButton(
                  label: 'Fit to screen',
                  icon: Icons.fit_screen_outlined,
                  onPressed: onFit,
                ),
            ],
          ),
          const SizedBox(height: T.s16),
          // Fixed-height strip: the chips inside are icon+label pills whose
          // text can scale, so this is sized from the text rather than pinned
          // to a magic number that would clip at large font sizes.
          SizedBox(
            height: 32 * MediaQuery.textScalerOf(context).scale(1),
            child: Semantics(
              explicitChildNodes: true,
              label: 'Filter statuses by category',
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: graph.categories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final c = graph.categories[i];
                  final style = CategoryStyle.of(c.id);
                  final on = !mutedCategories.contains(c.id);
                  return _CategoryChip(
                    label: c.label,
                    fill: style.fill,
                    icon: style.icon,
                    active: on,
                    onTap: () => onToggleCategory(c.id),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.graph,
    required this.onJump,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final PathwayGraph graph;
  final ValueChanged<String> onJump;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<PathwayNode>(
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        onChanged(value.text);
        if (q.isEmpty) return const Iterable<PathwayNode>.empty();
        return graph.nodes.where(
          (n) =>
              n.name.toLowerCase().contains(q) ||
              n.id.toLowerCase().contains(q),
        );
      },
      displayStringForOption: (n) => n.name,
      onSelected: (n) => onJump(n.id),
      fieldViewBuilder: (context, textController, focusNode, onSubmit) {
        return TextField(
          controller: textController,
          focusNode: focusNode,
          style: AppTheme.bodySm.copyWith(color: T.ink),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search a status, form or family…',
            hintStyle: AppTheme.bodySm,
            prefixIcon: const Icon(Icons.search, size: 17, color: T.pencilGray),
            prefixIconConstraints: const BoxConstraints(minWidth: 38),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.rInput),
              borderSide: T.hairline,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.rInput),
              borderSide: T.hairline,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.rInput),
              borderSide: const BorderSide(color: T.signalBlue, width: 1.5),
            ),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            color: T.paper,
            elevation: 0,
            borderRadius: BorderRadius.circular(T.rInput),
            child: Container(
              width: 300,
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                border: Border.fromBorderSide(T.hairline),
                borderRadius: BorderRadius.circular(T.rInput),
                boxShadow: T.floatShadow,
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                shrinkWrap: true,
                children: [
                  for (final option in options)
                    InkWell(
                      onTap: () => onSelected(option),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              CategoryStyle.of(option.categoryId).icon,
                              size: 14,
                              color: T.pencilGray,
                            ),
                            const SizedBox(width: T.s8),
                            Expanded(
                              child: Text(
                                option.name,
                                style: AppTheme.bodySm.copyWith(color: T.ink),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Toggle extends StatefulWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<_Toggle> {
  bool _focused = false;

  void _flip() => widget.onChanged(!widget.value);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // `toggled` is what makes a screen reader say "checked"/"not checked"
      // rather than reading this as a plain button whose state is invisible.
      toggled: widget.value,
      label: widget.label,
      onTap: _flip,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _flip();
              return null;
            },
          ),
        },
        child: GestureDetector(
          // Semantics are declared by the Semantics wrapper above this
          // control; without this the detector emits a second, unlabelled
          // tappable node beside it.
          excludeFromSemantics: true,
          onTap: _flip,
          child: ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: widget.value ? T.signalBlue : Colors.transparent,
                border: Border.all(
                  color: widget.value ? T.signalBlue : T.pencilGray,
                ),
                borderRadius: BorderRadius.circular(T.rPill),
                boxShadow: _focused ? focusRing(onFill: widget.value) : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.value ? Icons.check_circle : Icons.circle_outlined,
                    size: 14,
                    color: widget.value ? T.paper : T.graphite,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.label,
                    style: AppTheme.label.copyWith(
                      color: widget.value ? T.paper : T.carbon,
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

class _CategoryChip extends StatefulWidget {
  const _CategoryChip({
    required this.label,
    required this.fill,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final Color fill;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<_CategoryChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: widget.active,
      // The chip's meaning is "showing / hidden", which the fade alone conveys
      // only visually.
      label: '${widget.label} category, ${widget.active ? 'shown' : 'hidden'}',
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
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
                const Duration(milliseconds: 160),
              ),
              opacity: widget.active ? 1 : 0.42,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  border: Border.fromBorderSide(T.hairline),
                  borderRadius: BorderRadius.circular(T.rPill),
                  boxShadow: _focused ? focusRing() : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: widget.fill,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(widget.icon, size: 9, color: T.ink),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.label,
                      style: AppTheme.caption.copyWith(color: T.carbon),
                    ),
                    if (!widget.active) ...[
                      const SizedBox(width: 5),
                      const Icon(
                        Icons.visibility_off_outlined,
                        size: 11,
                        color: T.graphite,
                      ),
                    ],
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

// ── The non-visual equivalent ───────────────────────────────────────────────

/// The same graph as a plain nested list: category → status → the routes in and
/// out of it.
///
/// This exists because the map cannot be fixed. A `CustomPainter` canvas has no
/// structure to expose — the edges are pixels, and panning and zooming are
/// meaningless to a screen reader. Rather than pretend otherwise, the same
/// information is offered in a form that is natively navigable: real list
/// semantics, real headings, real buttons, ordinary Tab order, no viewport.
class PathwayListView extends StatelessWidget {
  const PathwayListView({
    super.key,
    required this.graph,
    required this.visible,
    required this.selectedId,
    required this.onSelect,
  });

  final PathwayGraph graph;

  /// Honours exactly the same search and category filters as the map, so the
  /// two views never disagree about what is on screen.
  final Set<String> visible;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final categories = [
      for (final c in graph.categories)
        (
          c,
          graph.nodes
              .where((n) => n.categoryId == c.id && visible.contains(n.id))
              .toList(),
        ),
    ].where((e) => e.$2.isNotEmpty).toList();

    return Semantics(
      explicitChildNodes: true,
      label:
          'Visa pathways as a list, ${visible.length} of '
          '${graph.nodes.length} statuses.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(T.s24, T.s24, T.s24, T.s40),
        children: [
          if (categories.isEmpty)
            Text('No statuses match the filters.', style: AppTheme.body)
          else
            for (final (category, nodes) in categories) ...[
              Semantics(
                header: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: T.s24, bottom: T.s8),
                  child: Text(
                    '${category.label} (${nodes.length})',
                    style: AppTheme.headingSm,
                  ),
                ),
              ),
              for (final node in nodes)
                _ListNode(
                  graph: graph,
                  node: node,
                  expanded: selectedId == node.id,
                  onToggle: () =>
                      onSelect(selectedId == node.id ? null : node.id),
                  onGoTo: onSelect,
                ),
            ],
        ],
      ),
    );
  }
}

/// One status in the list view. Collapsed it is a button; expanded it spells
/// out every route in and out, each of which is itself a button that moves you
/// there — the list equivalent of following an edge.
class _ListNode extends StatelessWidget {
  const _ListNode({
    required this.graph,
    required this.node,
    required this.expanded,
    required this.onToggle,
    required this.onGoTo,
  });

  final PathwayGraph graph;
  final PathwayNode node;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<String> onGoTo;

  @override
  Widget build(BuildContext context) {
    final out = graph.edgesFrom(node.id);
    final into = graph.edgesTo(node.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: T.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            label:
                '${node.name}. ${phaseLabel(node.phase)}. '
                '${out.length} routes out, ${into.length} routes in.',
            onTap: onToggle,
            child: ExcludeSemantics(
              child: ListTile(
                onTap: onToggle,
                dense: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(T.rInput),
                  side: T.hairline,
                ),
                leading: Icon(
                  CategoryStyle.of(node.categoryId).icon,
                  size: 18,
                  color: T.graphite,
                ),
                title: Text(
                  node.name,
                  style: AppTheme.bodySm.copyWith(
                    color: T.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${phaseLabel(node.phase)} · ${out.length} out · '
                  '${into.length} in',
                  style: AppTheme.caption,
                ),
                trailing: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: T.graphite,
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(T.s32, T.s8, 0, T.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (node.description.isNotEmpty) ...[
                    Text(node.description, style: AppTheme.bodySm),
                    const SizedBox(height: T.s8),
                  ],
                  for (final (heading, edges, forward) in [
                    ('Routes out', out, true),
                    ('Routes in', into, false),
                  ])
                    if (edges.isNotEmpty) ...[
                      Semantics(
                        header: true,
                        child: Text(
                          '$heading (${edges.length})',
                          style: AppTheme.label,
                        ),
                      ),
                      for (final e in edges)
                        _ListRoute(
                          label:
                              graph.node(forward ? e.to : e.from)?.name ??
                              (forward ? e.to : e.from),
                          detail: '${edgeTypeLabel(e.type)}. ${e.trigger}',
                          forward: forward,
                          onTap: () => onGoTo(forward ? e.to : e.from),
                        ),
                      const SizedBox(height: T.s8),
                    ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ListRoute extends StatelessWidget {
  const _ListRoute({
    required this.label,
    required this.detail,
    required this.forward,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool forward;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${forward ? 'Leads to' : 'Comes from'} $label. $detail',
      onTap: onTap,
      child: ExcludeSemantics(
        child: ListTile(
          onTap: onTap,
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            forward ? Icons.arrow_forward : Icons.arrow_back,
            size: 15,
            color: T.graphite,
          ),
          title: Text(label, style: AppTheme.bodySm.copyWith(color: T.ink)),
          subtitle: Text(detail, style: AppTheme.caption),
        ),
      ),
    );
  }
}

// ── Canvas furniture ────────────────────────────────────────────────────────

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.scale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
  });

  final double scale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rPill),
        boxShadow: T.floatShadow,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            iconSize: 17,
            tooltip: 'Zoom out',
            onPressed: onZoomOut,
            icon: const Icon(Icons.remove, color: T.carbon),
          ),
          Text(
            '${(scale * 100).round()}%',
            style: AppTheme.caption.copyWith(color: T.carbon),
          ),
          IconButton(
            iconSize: 17,
            tooltip: 'Zoom in',
            onPressed: onZoomIn,
            icon: const Icon(Icons.add, color: T.carbon),
          ),
          const SizedBox(
            height: 20,
            child: VerticalDivider(width: 1, color: T.pencilGray),
          ),
          IconButton(
            iconSize: 17,
            tooltip: 'Fit to screen',
            onPressed: onFit,
            icon: const Icon(Icons.fit_screen_outlined, color: T.carbon),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.count, required this.total});

  final int count;
  final int total;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // The legend is `Positioned` by two edges only, so its width is
      // unbounded — which the `Flexible` hint rows below cannot lay out
      // against. Give it a reading-width ceiling and they wrap instead.
      constraints: const BoxConstraints(maxWidth: 268),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: T.paper.withValues(alpha: 0.94),
          border: Border.fromBorderSide(T.hairline),
          borderRadius: BorderRadius.circular(T.rInput),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Showing $count of $total statuses',
              style: AppTheme.caption.copyWith(
                color: T.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Container(width: 18, height: 2, color: T.signalBlue),
                const SizedBox(width: 6),
                Flexible(
                  child: Text('Selected route', style: AppTheme.caption),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Container(width: 18, height: 1, color: T.pencilGray),
                const SizedBox(width: 6),
                Flexible(
                  child: Text('Documented transition', style: AppTheme.caption),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                const Icon(
                  Icons.hourglass_empty,
                  size: 11,
                  color: T.pencilGray,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text('Not yet modelled', style: AppTheme.caption),
                ),
              ],
            ),
            const SizedBox(height: T.s8),
            Row(
              children: [
                const Icon(
                  Icons.pan_tool_outlined,
                  size: 11,
                  color: T.pencilGray,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Drag to pan · scroll to zoom · shift+scroll to move',
                    style: AppTheme.caption,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            // The keyboard map is useless if nobody knows it is there, and the
            // people most likely to need it are the least likely to go hunting.
            Row(
              children: [
                const Icon(
                  Icons.keyboard_outlined,
                  size: 11,
                  color: T.pencilGray,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Keys: arrows move · enter opens · esc closes · + − 0 zoom',
                    style: AppTheme.caption,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = T.pencilGray.withValues(alpha: 0.20);
    const step = 28.0;
    for (var x = 0.0; x < size.width; x += step) {
      for (var y = 0.0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter oldDelegate) => false;
}
