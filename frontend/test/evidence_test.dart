import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/models/evidence.dart';
import 'package:lumos/services/evidence_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The evidence tracker's contract.
///
/// The load-bearing assertions are the ones about *structure*: EB-1B and EB-1C
/// must never be scored by counting criteria, because that would tell somebody
/// they were ready when a gating requirement they cannot satisfy is missing.
void main() {
  late EvidenceCatalog catalog;
  late EvidenceService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    catalog = EvidenceService.embeddedCatalog();
    service = EvidenceService.instance;
    service.useCatalog(catalog);
    await service.clearAll();
  });

  EvidenceSet set(String id) => catalog.set(id)!;

  Future<void> mark(Iterable<String> ids, EvidenceStrength strength) async {
    for (final id in ids) {
      await service.setStrength(id, strength);
    }
  }

  // ── Catalog shape ─────────────────────────────────────────────────────────

  group('catalog', () {
    test('covers all six criteria sets with the right structures', () {
      expect(
        catalog.sets.map((s) => s.id),
        ['o1a', 'o1b_arts', 'o1b_mptv', 'eb1a', 'eb1b', 'eb1c'],
      );

      expect(set('o1a').criteria, hasLength(8));
      expect(set('o1a').threshold, 3);
      expect(set('o1b_arts').criteria, hasLength(6));
      expect(set('o1b_mptv').criteria, hasLength(6));
      expect(set('eb1a').criteria, hasLength(10));
      expect(set('eb1a').threshold, 3);

      expect(set('eb1b').gates, hasLength(3));
      expect(set('eb1b').criteria, hasLength(6));
      expect(set('eb1c').conditions, hasLength(5));
      expect(set('eb1c').criteria, isEmpty);
      expect(set('eb1c').threshold, isNull);
    });

    test('EB-1A models the two-step determination explicitly', () {
      final eb1a = set('eb1a');
      expect(eb1a.structure, EvidenceStructure.criteriaCountWithFinalMerits);
      expect(eb1a.twoStep, isNotNull);
      expect(eb1a.twoStep!.stepTwoMeans, isNotEmpty);
      expect(eb1a.twoStep!.whyItMatters, isNotEmpty);
      // Nothing else claims a two-step structure.
      expect(
        catalog.sets.where((s) => s.twoStep != null).map((s) => s.id),
        ['eb1a'],
      );
    });

    test('every item carries the fields the detail screen needs', () {
      for (final s in catalog.sets) {
        for (final item in s.allItems) {
          expect(item.id, isNotEmpty, reason: '${s.id} item id');
          expect(item.name, isNotEmpty, reason: item.id);
          expect(item.means, isNotEmpty, reason: item.id);
          expect(item.typicallyCounts, isNotEmpty, reason: item.id);
          expect(item.typicallyDoesNotCount, isNotEmpty, reason: item.id);
          expect(item.howToBuild, isNotEmpty, reason: item.id);
          expect(item.timeToBuild, isNotEmpty, reason: item.id);
        }
      }
    });

    test('the disclaimer is present and says it is not legal advice', () {
      expect(catalog.meta.disclaimer.toLowerCase(), contains('not legal advice'));
      expect(catalog.meta.disclaimer.toLowerCase(), contains('attorney'));
      expect(catalog.meta.privacyNote, isNotEmpty);
    });

    test('the docs, asset and embedded copies do not drift', () {
      final docs = File('../docs/evidence_criteria_o1_eb1.json');
      final asset = File('assets/data/evidence_criteria_o1_eb1.json');
      // Skip rather than fail if the test is run from an unusual cwd.
      if (!docs.existsSync() || !asset.existsSync()) return;

      final embedded = jsonDecode(embeddedCriteriaJson);
      expect(jsonDecode(docs.readAsStringSync()), embedded);
      expect(jsonDecode(asset.readAsStringSync()), embedded);
    });
  });

  // ── Readiness: the threshold boundary ─────────────────────────────────────

  group('readiness at the threshold boundary', () {
    test('O-1A: two met is below, three met is at the typical threshold',
        () async {
      final o1a = set('o1a');
      expect(service.readinessFor(o1a).meetsTypicalThreshold, isFalse);
      expect(service.readinessFor(o1a).criteriaMet, 0);
      expect(service.readinessFor(o1a).hasStarted, isFalse);

      await mark(
        ['o1a.judging', 'o1a.high_remuneration'],
        EvidenceStrength.haveEvidence,
      );
      var r = service.readinessFor(o1a);
      expect(r.criteriaMet, 2);
      expect(r.meetsTypicalThreshold, isFalse);
      expect(r.criteriaGap, 1);
      expect(r.headline, contains('One more'));

      await mark(['o1a.authorship'], EvidenceStrength.strong);
      r = service.readinessFor(o1a);
      expect(r.criteriaMet, 3);
      expect(r.meetsTypicalThreshold, isTrue);
      expect(r.criteriaGap, 0);
      expect(r.progress, 1.0);
    });

    test('"in progress" does not count toward the threshold', () async {
      final o1a = set('o1a');
      await mark(
        ['o1a.judging', 'o1a.authorship', 'o1a.awards'],
        EvidenceStrength.inProgress,
      );
      final r = service.readinessFor(o1a);
      expect(r.criteriaMet, 0);
      expect(r.criteriaMoving, 3);
      expect(r.meetsTypicalThreshold, isFalse);
      // Started, though — the screen should not say "nothing recorded".
      expect(r.hasStarted, isTrue);
    });

    test('EB-1A counts to three but never claims the final merits step',
        () async {
      final eb1a = set('eb1a');
      await mark(
        ['eb1a.judging', 'eb1a.authorship', 'eb1a.high_remuneration'],
        EvidenceStrength.haveEvidence,
      );
      final r = service.readinessFor(eb1a);
      expect(r.meetsTypicalThreshold, isTrue);
      expect(r.detail.toLowerCase(), contains('step one'));
      expect(r.detail.toLowerCase(), contains('whole record'));
    });
  });

  // ── Readiness: per-visa-type differences ──────────────────────────────────

  group('per-visa-type structures', () {
    test('only O-1A, O-1B and EB-1A are criteria-counted', () {
      final counted = catalog.sets
          .where((s) => service.readinessFor(s).isCriteriaCounted)
          .map((s) => s.id);
      expect(counted, ['o1a', 'o1b_arts', 'o1b_mptv', 'eb1a']);
    });

    test('EB-1B is NOT scored by criteria-counting: unmet gates veto',
        () async {
      final eb1b = set('eb1b');
      // Every criterion met — far past the threshold of two.
      await mark(
        eb1b.criteria.map((c) => c.id),
        EvidenceStrength.strong,
      );
      final r = service.readinessFor(eb1b);

      expect(r.isCriteriaCounted, isFalse);
      expect(r.criteriaMet, 6);
      expect(
        r.meetsTypicalThreshold,
        isFalse,
        reason: 'gates are unmet, so a full criteria sweep must not read as '
            'ready',
      );
      expect(r.progress, lessThan(1.0));
      expect(r.headline.toLowerCase(), contains('gated'));
      expect(r.detail, contains('not scored by counting alone'));

      // Clearing the gates is what actually changes the answer.
      await mark(eb1b.gates.map((g) => g.id), EvidenceStrength.haveEvidence);
      final after = service.readinessFor(eb1b);
      expect(after.meetsTypicalThreshold, isTrue);
      expect(after.mandatoryMet, 3);
    });

    test('EB-1B gates met but criteria short is still not ready', () async {
      final eb1b = set('eb1b');
      await mark(eb1b.gates.map((g) => g.id), EvidenceStrength.strong);
      await mark(['eb1b.judging'], EvidenceStrength.haveEvidence);
      final r = service.readinessFor(eb1b);
      expect(r.mandatoryMet, 3);
      expect(r.criteriaMet, 1);
      expect(r.meetsTypicalThreshold, isFalse);
      expect(r.criteriaGap, 1);
    });

    test('EB-1C is NOT scored by criteria-counting: every condition must hold',
        () async {
      final eb1c = set('eb1c');
      final r0 = service.readinessFor(eb1c);
      expect(r0.isCriteriaCounted, isFalse);
      expect(r0.criteriaTotal, 0);
      expect(r0.threshold, isNull);
      expect(r0.detail, contains('nothing to count'));

      final ids = eb1c.conditions.map((c) => c.id).toList();
      await mark(ids.take(4), EvidenceStrength.strong);
      final partial = service.readinessFor(eb1c);
      expect(partial.mandatoryMet, 4);
      expect(
        partial.meetsTypicalThreshold,
        isFalse,
        reason: 'four of five conditions is not "close enough" — there is no '
            'threshold to be close to',
      );

      await mark([ids.last], EvidenceStrength.haveEvidence);
      expect(service.readinessFor(eb1c).meetsTypicalThreshold, isTrue);
    });

    test('readiness never reports a criteria gap for EB-1C', () {
      expect(service.readinessFor(set('eb1c')).criteriaGap, isNull);
    });
  });

  // ── Next-action suggestions ───────────────────────────────────────────────

  group('next action ranking', () {
    test('from zero, the cheapest-to-build criteria come first', () {
      final actions = service.nextActions(set('o1a'));
      expect(actions, hasLength(2));
      // Judging and remuneration are the two "weeks" criteria on O-1A.
      expect(
        actions.map((a) => a.item.id),
        containsAll(<String>['o1a.judging', 'o1a.high_remuneration']),
      );
      for (final a in actions) {
        expect(a.item.effort, BuildEffort.weeks);
      }
    });

    test('something already in progress outranks an untouched cheap one',
        () async {
      await service.setStrength(
        'o1a.original_contributions',
        EvidenceStrength.inProgress,
      );
      final actions = service.nextActions(set('o1a'), limit: 3);
      expect(actions.first.item.effort, BuildEffort.weeks);
      // The years-long criterion is lifted above the other untouched
      // months-long ones by being in motion.
      final ranked = actions.map((a) => a.item.id).toList();
      expect(ranked, contains('o1a.original_contributions'));
      expect(
        actions
            .firstWhere((a) => a.item.id == 'o1a.original_contributions')
            .rationale,
        contains('already started'),
      );
    });

    test('criteria already met are never suggested', () async {
      await mark(['o1a.judging'], EvidenceStrength.strong);
      final actions = service.nextActions(set('o1a'), limit: 8);
      expect(actions.map((a) => a.item.id), isNot(contains('o1a.judging')));
    });

    test('mandatory gates and conditions outrank ordinary criteria', () {
      final eb1b = service.nextActions(set('eb1b'));
      expect(eb1b.every((a) => a.item.isMandatory), isTrue);
      expect(eb1b.first.rationale, contains('cannot work without'));

      final eb1c = service.nextActions(set('eb1c'));
      expect(eb1c.every((a) => a.item.kind == EvidenceItemKind.condition),
          isTrue);
    });

    test('criteria that may not apply to this person are demoted', () {
      final actions = service.nextActions(set('eb1a'), limit: 10);
      final ids = actions.map((a) => a.item.id).toList();
      // Exhibitions and performing-arts commercial success both carry an
      // applicability note; neither should be an opening suggestion.
      expect(ids.indexOf('eb1a.exhibitions'), greaterThan(2));
      expect(ids.indexOf('eb1a.commercial_success'), greaterThan(2));
    });

    test('ranking is stable and deterministic', () {
      final a = service.nextActions(set('o1b_arts'), limit: 6);
      final b = service.nextActions(set('o1b_arts'), limit: 6);
      expect(a.map((x) => x.item.id), b.map((x) => x.item.id));
    });

    test('scores are non-increasing down the list', () {
      final actions = service.nextActions(set('eb1a'), limit: 10);
      for (var i = 1; i < actions.length; i++) {
        expect(actions[i - 1].score, greaterThanOrEqualTo(actions[i].score));
      }
    });
  });

  // ── Persistence ───────────────────────────────────────────────────────────

  group('persistence', () {
    test('strength and notes survive a reload from storage', () async {
      await service.setStrength('o1a.judging', EvidenceStrength.strong);
      await service.setNotes(
        'o1a.judging',
        'Reviewed 3 papers for the workshop; invitation email saved.',
      );

      // Simulate a fresh browser session against the same local storage.
      service.forget();
      expect(service.strengthFor('o1a.judging'), EvidenceStrength.notStarted);

      service.useCatalog(catalog);
      final reloaded = EvidenceService.instance;
      await reloaded.load();

      expect(reloaded.strengthFor('o1a.judging'), EvidenceStrength.strong);
      expect(
        reloaded.assessmentFor('o1a.judging').notes,
        contains('invitation email saved'),
      );
      expect(reloaded.readinessFor(set('o1a')).criteriaMet, 1);
    });

    test('an assessment reset to nothing is dropped rather than stored',
        () async {
      await service.setStrength('o1a.awards', EvidenceStrength.haveEvidence);
      expect(service.assessments.containsKey('o1a.awards'), isTrue);

      await service.setStrength('o1a.awards', EvidenceStrength.notStarted);
      expect(service.assessments.containsKey('o1a.awards'), isFalse);
      expect(service.readinessFor(set('o1a')).hasStarted, isFalse);
    });

    test('clearAll wipes both memory and storage', () async {
      await service.setStrength('eb1a.judging', EvidenceStrength.strong);
      await service.clearAll();

      service.forget();
      service.useCatalog(catalog);
      await EvidenceService.instance.load();
      expect(EvidenceService.instance.assessments, isEmpty);
    });

    test('an assessment round-trips through JSON without loss', () {
      final original = EvidenceAssessment(
        itemId: 'eb1c.cond.prior_employment',
        strength: EvidenceStrength.inProgress,
        notes: 'Asking HR abroad for the dates.',
        updatedAt: DateTime(2026, 8, 15, 9, 30),
      );
      final restored = EvidenceAssessment.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored.itemId, original.itemId);
      expect(restored.strength, original.strength);
      expect(restored.notes, original.notes);
      expect(restored.updatedAt, original.updatedAt);
    });
  });

  // ── Privacy ───────────────────────────────────────────────────────────────

  test('the stored payload holds only self-assessment and notes', () async {
    await service.setStrength('o1a.judging', EvidenceStrength.strong);
    await service.setNotes('o1a.judging', 'my own words');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('lumos.evidence')!;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final entry =
        (decoded['assessments'] as Map).values.first as Map<String, dynamic>;

    expect(entry.keys.toSet(), {'itemId', 'strength', 'notes', 'updatedAt'});
    // No document, file, attachment or upload field anywhere in the model.
    expect(raw.toLowerCase(), isNot(contains('attachment')));
    expect(raw.toLowerCase(), isNot(contains('upload')));
  });
}
