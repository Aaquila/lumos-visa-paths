import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/pathway_graph.dart';

/// Loads the generic pathway graph.
///
/// Today this reads the bundled asset (a copy of `docs/generic_pathways.json`).
/// When the backend lands, swap the body of [load] for `GET /api/pathways/generic`
/// — see `backend/docs/API_ENDPOINTS.md` — the parsed shape does not change.
class PathwayRepository {
  PathwayRepository._();
  static final instance = PathwayRepository._();

  static const assetPath = 'assets/data/generic_pathways.json';

  Future<PathwayGraph>? _cached;

  Future<PathwayGraph> load() => _cached ??= _loadFromAsset();

  Future<PathwayGraph> _loadFromAsset() async {
    final raw = await rootBundle.loadString(assetPath);
    return PathwayGraph.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }
}
