import 'dart:math' as math;

/// Parsed shape of `assets/data/generic_pathways.json`
/// (source of truth: `docs/generic_pathways.json`).

class PathwayCategory {
  const PathwayCategory({
    required this.id,
    required this.label,
    required this.type,
  });

  final String id;
  final String label;

  /// nonimmigrant | immigrant | humanitarian | post_lpr
  final String type;

  factory PathwayCategory.fromJson(Map<String, dynamic> j) => PathwayCategory(
    id: j['id'] as String,
    label: j['label'] as String,
    type: j['type'] as String,
  );
}

class PathwayNode {
  const PathwayNode({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.workAuthorized,
    required this.dualIntent,
    required this.keyForms,
    required this.recurringDeadlines,
    required this.sourceHints,
    required this.phase,
    this.requirements = const [],
    this.parentId,
    this.childIds = const [],
    this.isSubCheckpoint = false,
  });

  final String id;
  final String categoryId;
  final String name;
  final String description;
  final String workAuthorized;

  /// The JSON stores either a bool or a qualifying string ("de facto …").
  final String dualIntent;
  final List<String> keyForms;
  final List<String> recurringDeadlines;
  final List<String> sourceHints;

  /// Structural conditions this status or filing actually requires — what has
  /// to be true before the route is usable at all.
  final List<String> requirements;

  /// Rollout phase from `meta.rollout_order`; 0 = MVP-modeled, 3 = furthest out.
  final int phase;

  /// Parent checkpoint ID if this is a sub-checkpoint (e.g., h1b.labor_cert)
  final String? parentId;

  /// List of child checkpoint IDs for sub-checkpoints
  final List<String> childIds;

  /// True if this node is a sub-checkpoint under a parent
  final bool isSubCheckpoint;

  /// Phase 0 families are the ones wired to live reasoning today; everything
  /// else renders greyed-out as "not yet modeled" (PROJECT_PRD §3).
  bool get isModeled => phase == 0;

  String get family => id.split('.').first;

  factory PathwayNode.fromJson(Map<String, dynamic> j, int phase) {
    final dual = j['dual_intent'];
    return PathwayNode(
      id: j['id'] as String,
      categoryId: j['category'] as String,
      name: j['name'] as String,
      description: j['description'] as String? ?? '',
      workAuthorized: j['work_authorized'] as String? ?? '',
      dualIntent: dual is bool ? (dual ? 'Yes' : 'No') : '${dual ?? '—'}',
      keyForms: (j['key_forms'] as List? ?? const []).cast<String>(),
      recurringDeadlines: (j['recurring_deadlines'] as List? ?? const [])
          .cast<String>(),
      requirements: (j['requirements'] as List? ?? const []).cast<String>(),
      sourceHints: ((j['source_hint'] as String?) ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      phase: phase,
      parentId: j['parent_id'] as String?,
      childIds: (j['child_ids'] as List? ?? const []).cast<String>(),
      isSubCheckpoint: j['is_sub_checkpoint'] as bool? ?? false,
    );
  }
}

class PathwayEdge {
  const PathwayEdge({
    required this.from,
    required this.to,
    required this.type,
    required this.trigger,
    this.optional = false,
    this.note,
  });

  final String from;
  final String to;

  /// authorization | extension | change_of_status | petition | adjustment |
  /// priority_date_transfer | …
  final String type;
  final String trigger;

  /// True when this route skips a step people commonly assume is mandatory —
  /// F-1 → H-1B, for instance, because OPT and STEM OPT are optional.
  final bool optional;

  /// A caveat that changes whether the edge is usable at all.
  final String? note;

  bool get isSelfLoop => from == to;

  /// Lateral moves inside the same stage — interfiling between EB categories,
  /// H-1B portability. They retain a priority date or an employer rather than
  /// advancing along the path, so the layout must not treat them as progress.
  static const lateralTypes = {
    'priority_date_transfer',
    'employer_change',
    'auto_upgrade',
    'auto_convert',
  };

  bool get isLateral => lateralTypes.contains(type);

  factory PathwayEdge.fromJson(Map<String, dynamic> j) => PathwayEdge(
    from: j['from'] as String,
    to: j['to'] as String,
    type: j['type'] as String? ?? '',
    trigger: j['trigger'] as String? ?? '',
    optional: j['optional'] as bool? ?? false,
    note: j['note'] as String?,
  );
}

/// The whole graph plus a deterministic left-to-right layered layout.
class PathwayGraph {
  PathwayGraph({
    required this.title,
    required this.asOf,
    required this.warning,
    required this.categories,
    required this.nodes,
    required this.edges,
  }) {
    _nodesById = {for (final n in nodes) n.id: n};
    _categoriesById = {for (final c in categories) c.id: c};
    _layout();
  }

  final String title;
  final String asOf;
  final String warning;
  final List<PathwayCategory> categories;
  final List<PathwayNode> nodes;
  final List<PathwayEdge> edges;

  late final Map<String, PathwayNode> _nodesById;
  late final Map<String, PathwayCategory> _categoriesById;

  /// Layout results, in graph-space pixels.
  final Map<String, ({double x, double y})> positions = {};
  double canvasWidth = 0;
  double canvasHeight = 0;

  PathwayNode? node(String id) => _nodesById[id];
  PathwayCategory? category(String id) => _categoriesById[id];

  /// Get all child checkpoints of a parent node
  List<PathwayNode> children(String parentId) =>
      nodes.where((n) => n.parentId == parentId).toList();

  /// Get the parent checkpoint of a sub-checkpoint
  PathwayNode? parent(String nodeId) {
    final node = this.node(nodeId);
    return node?.parentId != null ? this.node(node!.parentId!) : null;
  }

  List<PathwayEdge> edgesFrom(String id) =>
      edges.where((e) => e.from == id && !e.isSelfLoop).toList();
  List<PathwayEdge> edgesTo(String id) =>
      edges.where((e) => e.to == id && !e.isSelfLoop).toList();
  List<PathwayEdge> selfLoops(String id) =>
      edges.where((e) => e.from == id && e.isSelfLoop).toList();

  /// Every node reachable downstream of [id], for the "highlight my route" mode.
  Set<String> reachableFrom(String id) {
    final seen = <String>{};
    final queue = <String>[id];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final e in edgesFrom(current)) {
        if (seen.add(e.to)) queue.add(e.to);
      }
    }
    return seen;
  }

  /// The ordered chain of node ids from [currentNodeId] to [goalNodeId],
  /// forward-only (same directed-edge assumption [reachableFrom] and the
  /// layout make). Returns `null` when there is no forward path — the caller
  /// should fall back to something else rather than show a route going
  /// backwards.
  List<String>? computeRoute(String currentNodeId, String goalNodeId) {
    if (currentNodeId == goalNodeId) return [currentNodeId];

    final predecessor = <String, String>{};
    final visited = <String>{currentNodeId};
    final queue = <String>[currentNodeId];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final e in edgesFrom(current)) {
        if (!visited.add(e.to)) continue;
        predecessor[e.to] = current;
        if (e.to == goalNodeId) {
          final path = <String>[goalNodeId];
          var step = goalNodeId;
          while (step != currentNodeId) {
            step = predecessor[step]!;
            path.add(step);
          }
          return path.reversed.toList();
        }
        queue.add(e.to);
      }
    }
    return null;
  }

  // ── Layout ────────────────────────────────────────────────────────────────

  static const nodeWidth = 232.0;

  /// Tall enough for two full lines of title above the meta row — several
  /// status names ("EB-3 Skilled Workers / Professionals / Other Workers")
  /// genuinely need both.
  static const nodeHeight = 108.0;
  static const _colGap = 116.0;
  static const _rowGap = 34.0;
  static const _margin = 72.0;

  /// Longest-path layering: a node sits one column right of its deepest
  /// predecessor, so every edge points left-to-right and the F-1 → OPT →
  /// H-1B → EB → green card spine reads as a straight run.
  void _layout() {
    final depth = <String, int>{};
    final incoming = <String, List<String>>{
      for (final n in nodes) n.id: <String>[],
    };
    for (final e in edges) {
      // Self-loops and lateral moves (interfiling, portability) are not forward
      // progress, so they must not push a node into a later column — and
      // EB-3 ↔ EB-2 interfiling would otherwise be a cycle.
      if (e.isSelfLoop || e.isLateral) continue;
      incoming[e.to]?.add(e.from);
    }

    int depthOf(String id, Set<String> visiting) {
      final cached = depth[id];
      if (cached != null) return cached;
      // Guard against any cycle that creeps into the data later.
      if (!visiting.add(id)) return 0;
      var d = 0;
      for (final from in incoming[id] ?? const <String>[]) {
        d = math.max(d, depthOf(from, visiting) + 1);
      }
      visiting.remove(id);
      return depth[id] = d;
    }

    for (final n in nodes) {
      depthOf(n.id, <String>{});
    }

    // Group by column, then order within the column by category so related
    // families stack together instead of interleaving.
    final categoryOrder = {
      for (var i = 0; i < categories.length; i++) categories[i].id: i,
    };
    final columns = <int, List<PathwayNode>>{};
    for (final n in nodes) {
      columns.putIfAbsent(depth[n.id] ?? 0, () => []).add(n);
    }
    for (final column in columns.values) {
      column.sort((a, b) {
        final byCategory = (categoryOrder[a.categoryId] ?? 99).compareTo(
          categoryOrder[b.categoryId] ?? 99,
        );
        return byCategory != 0 ? byCategory : a.name.compareTo(b.name);
      });
    }

    final tallest = columns.values
        .map((c) => c.length * (nodeHeight + _rowGap) - _rowGap)
        .fold<double>(0, math.max);

    for (final entry in columns.entries) {
      final columnHeight =
          entry.value.length * (nodeHeight + _rowGap) - _rowGap;
      // Center each column vertically so the graph reads as a fan, not a grid.
      final top = _margin + (tallest - columnHeight) / 2;
      for (var i = 0; i < entry.value.length; i++) {
        positions[entry.value[i].id] = (
          x: _margin + entry.key * (nodeWidth + _colGap),
          y: top + i * (nodeHeight + _rowGap),
        );
      }
    }

    final maxColumn = columns.keys.fold<int>(0, math.max);
    canvasWidth =
        _margin * 2 + (maxColumn + 1) * (nodeWidth + _colGap) - _colGap;
    canvasHeight = _margin * 2 + tallest;
  }

  factory PathwayGraph.fromJson(Map<String, dynamic> j) {
    final meta = (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {};

    // Resolve each node's rollout phase from the `meta.rollout_order` patterns
    // ("student.*", "temp_worker.h1b", …). Anything unlisted lands in phase 3.
    final phaseByPattern = <String, int>{};
    for (final entry in (meta['rollout_order'] as List? ?? const [])) {
      final map = (entry as Map).cast<String, dynamic>();
      final phase = (map['phase'] as num).toInt();
      for (final pattern in (map['families'] as List? ?? const [])) {
        phaseByPattern[pattern as String] = phase;
      }
    }
    int phaseFor(String nodeId) {
      if (phaseByPattern.containsKey(nodeId)) return phaseByPattern[nodeId]!;
      final wildcard = '${nodeId.split('.').first}.*';
      return phaseByPattern[wildcard] ?? 3;
    }

    return PathwayGraph(
      title: meta['title'] as String? ?? 'US Immigration Pathways',
      asOf: meta['as_of'] as String? ?? '',
      warning: meta['warning'] as String? ?? '',
      categories: [
        for (final c in (j['categories'] as List? ?? const []))
          PathwayCategory.fromJson((c as Map).cast<String, dynamic>()),
      ],
      nodes: [
        for (final n in (j['nodes'] as List? ?? const []))
          PathwayNode.fromJson(
            (n as Map).cast<String, dynamic>(),
            phaseFor((n)['id'] as String),
          ),
      ],
      edges: [
        for (final e in (j['edges'] as List? ?? const []))
          PathwayEdge.fromJson((e as Map).cast<String, dynamic>()),
      ],
    );
  }
}
