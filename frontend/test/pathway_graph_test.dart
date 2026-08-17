import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/models/pathway_graph.dart';
import 'package:lumos/services/pathway_repository.dart';

/// Parses the shipped asset directly so the test fails if the data file and the
/// model drift apart.
PathwayGraph loadGraph() {
  final file = File(PathwayRepository.assetPath);
  return PathwayGraph.fromJson(
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
  );
}

void main() {
  late PathwayGraph graph;

  setUpAll(() => graph = loadGraph());

  test('every node parses and belongs to a declared category', () {
    expect(graph.nodes, isNotEmpty);
    final categoryIds = {for (final c in graph.categories) c.id};
    for (final node in graph.nodes) {
      expect(node.name, isNotEmpty, reason: node.id);
      expect(categoryIds, contains(node.categoryId), reason: node.id);
    }
  });

  test('every edge connects two known nodes', () {
    final ids = {for (final n in graph.nodes) n.id};
    for (final edge in graph.edges) {
      expect(ids, contains(edge.from));
      expect(ids, contains(edge.to));
    }
  });

  test('rollout phases resolve, including wildcard families', () {
    expect(graph.node('student.f1')!.phase, 0, reason: 'matched by student.*');
    expect(graph.node('temp_worker.h1b')!.phase, 0, reason: 'matched exactly');
    expect(graph.node('extraordinary.o1')!.phase, 1);
    expect(graph.node('employment_gc.eb5')!.phase, 2);
    expect(graph.node('humanitarian.asylum')!.phase, 3);

    // The MVP spine is what renders as fully modelled.
    expect(graph.node('student.stem_opt')!.isModeled, isTrue);
    expect(graph.node('intracompany.l1')!.isModeled, isFalse);
  });

  test('layout places every node and forward edges run left to right', () {
    for (final node in graph.nodes) {
      expect(graph.positions[node.id], isNotNull, reason: node.id);
    }
    expect(graph.canvasWidth, greaterThan(0));
    expect(graph.canvasHeight, greaterThan(0));

    // Longest-path layering means the F-1 spine strictly advances.
    const spine = [
      'student.f1',
      'student.opt_postcompletion',
      'student.stem_opt',
      'student.cap_gap',
      'temp_worker.h1b',
      'employment_gc.eb2',
      'post_lpr.lpr',
      'post_lpr.naturalization',
    ];
    for (var i = 0; i < spine.length - 1; i++) {
      expect(
        graph.positions[spine[i]]!.x,
        lessThan(graph.positions[spine[i + 1]]!.x),
        reason: '${spine[i]} should sit left of ${spine[i + 1]}',
      );
    }
  });

  group('F-1 family structure', () {
    bool hasEdge(String from, String to) =>
        graph.edges.any((e) => e.from == from && e.to == to);

    test('OPT and STEM OPT are optional, not prerequisites for H-1B', () {
      // A student can be petitioned for H-1B straight out of F-1.
      expect(hasEdge('student.f1', 'temp_worker.h1b'), isTrue);
      expect(
        graph.edges
            .firstWhere(
              (e) => e.from == 'student.f1' && e.to == 'temp_worker.h1b',
            )
            .optional,
        isTrue,
        reason: 'the direct route must be flagged as skipping optional steps',
      );

      // …and from either practical-training step.
      expect(hasEdge('student.opt_postcompletion', 'temp_worker.h1b'), isTrue);
      expect(hasEdge('student.stem_opt', 'temp_worker.h1b'), isTrue);
      expect(hasEdge('student.cap_gap', 'temp_worker.h1b'), isTrue);
    });

    test('STEM OPT is only reachable from post-completion OPT', () {
      final into = graph.edgesTo('student.stem_opt').map((e) => e.from).toSet();
      expect(into, {'student.opt_postcompletion'},
          reason: 'STEM OPT extends post-completion OPT; it cannot be entered '
              'from F-1 or from pre-completion OPT directly');
    });

    test('the employment green card is reachable without ever holding H-1B', () {
      for (final from in const [
        'student.opt_postcompletion',
        'student.stem_opt',
      ]) {
        expect(hasEdge(from, 'employment_gc.eb2'), isTrue, reason: from);
        expect(hasEdge(from, 'employment_gc.eb3'), isTrue, reason: from);
        expect(hasEdge(from, 'employment_gc.eb2_niw'), isTrue, reason: from);
      }
      // NIW self-petitions need no employer, so they hang off F-1 itself.
      expect(hasEdge('student.f1', 'employment_gc.eb2_niw'), isTrue);
    });
  });

  group('EB-2 has two distinct routes', () {
    test('PERM and NIW are separate nodes with different requirements', () {
      final perm = graph.node('employment_gc.eb2')!;
      final niw = graph.node('employment_gc.eb2_niw')!;

      expect(perm.requirements, isNotEmpty);
      expect(niw.requirements, isNotEmpty);
      expect(
        perm.keyForms.any((f) => f.contains('PERM')),
        isTrue,
        reason: 'the employer route runs through PERM',
      );
      expect(
        niw.keyForms.any((f) => f.contains('PERM')),
        isFalse,
        reason: 'the NIW route waives PERM entirely',
      );
      // Both land in the same queue.
      expect(graph.edgesFrom(perm.id).map((e) => e.to), contains('post_lpr.lpr'));
      expect(graph.edgesFrom(niw.id).map((e) => e.to), contains('post_lpr.lpr'));
    });

    test('interfiling between EB categories is lateral, not progress', () {
      final interfile = graph.edges.where(
        (e) => e.type == 'priority_date_transfer',
      );
      expect(interfile, isNotEmpty);
      for (final e in interfile) {
        expect(e.isLateral, isTrue);
      }
      // EB-2 ↔ EB-3 is a genuine two-way cycle in the data; the layout must
      // still terminate and must not stack them in the same column ordering.
      expect(
        graph.edges.any(
          (e) => e.from == 'employment_gc.eb2' && e.to == 'employment_gc.eb3',
        ),
        isTrue,
      );
      expect(
        graph.edges.any(
          (e) => e.from == 'employment_gc.eb3' && e.to == 'employment_gc.eb2',
        ),
        isTrue,
      );
    });
  });

  test('reachableFrom walks the graph without looping forever', () {
    final reachable = graph.reachableFrom('student.f1');
    expect(reachable, contains('temp_worker.h1b'));
    expect(reachable, contains('post_lpr.naturalization'));
    // H-1B portability and the AC21 extension past year six are self-loops,
    // and must not be treated as routes out of H-1B.
    expect(
      graph.selfLoops('temp_worker.h1b').map((e) => e.type),
      containsAll(<String>['employer_change', 'extension']),
    );
    expect(
      graph.edgesFrom('temp_worker.h1b').map((e) => e.to),
      isNot(contains('temp_worker.h1b')),
    );
  });
}
