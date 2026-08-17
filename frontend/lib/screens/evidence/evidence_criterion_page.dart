import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/evidence.dart';
import '../../services/evidence_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/evidence_disclaimer.dart';
import '../../widgets/evidence_strength_picker.dart';
import '../../widgets/pill_button.dart';
import 'evidence_scaffold.dart';

/// `/evidence/:setId/:itemId` — one criterion, one screen.
///
/// The order is deliberate: what it means, what counts, what does *not* count,
/// how to build it, roughly how long — and only then the self-assessment.
/// Somebody should be able to read this without knowing anything, and stop
/// after the first two blocks without losing the point.
class EvidenceCriterionPage extends StatelessWidget {
  const EvidenceCriterionPage({
    super.key,
    required this.setId,
    required this.itemId,
  });

  final String setId;
  final String itemId;

  @override
  Widget build(BuildContext context) {
    return EvidenceLoader(
      builder: (context, service) {
        final set = service.catalog!.set(setId);
        final item = set?.item(itemId);
        if (set == null || item == null) {
          return EvidenceScaffold(
            children: [
              Text(
                'That criterion could not be found.',
                style: AppTheme.headingSm,
              ),
              const SizedBox(height: T.s16),
              PillButton(
                label: 'Back to the overview',
                onPressed: () => context.go('/evidence'),
              ),
            ],
          );
        }

        final siblings = set.allItems;
        final index = siblings.indexWhere((i) => i.id == item.id);

        return EvidenceScaffold(
          children: [
            _BackLink(
              label: set.visaCode,
              onTap: () => context.go('/evidence/$setId'),
            ),
            const SizedBox(height: T.s24),

            Text(switch (item.kind) {
              EvidenceItemKind.criterion =>
                'Criterion ${index + 1 - set.gates.length - set.conditions.length} of ${set.criteria.length}',
              EvidenceItemKind.gate => 'Requirement',
              EvidenceItemKind.condition => 'Condition',
            }, style: AppTheme.badge.copyWith(color: T.graphite)),
            const SizedBox(height: T.s8),
            Text(item.name, style: AppTheme.heading(context)),

            const SizedBox(height: T.s24),
            _Block(
              title: 'What this means',
              icon: Icons.chat_bubble_outline,
              child: Text(item.means, style: AppTheme.body),
            ),

            if (item.applicabilityNote != null) ...[
              const SizedBox(height: T.s16),
              Container(
                padding: const EdgeInsets.all(T.s16),
                decoration: BoxDecoration(
                  color: T.pastelMint.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(T.rInput),
                ),
                child: Text(
                  item.applicabilityNote!,
                  style: AppTheme.bodySm.copyWith(color: T.carbon),
                ),
              ),
            ],

            if (item.typicallyCounts.isNotEmpty) ...[
              const SizedBox(height: T.s24),
              _Block(
                title: 'What typically counts',
                icon: Icons.check_circle_outline,
                child: EvidenceBullets(items: item.typicallyCounts),
              ),
            ],

            if (item.typicallyDoesNotCount.isNotEmpty) ...[
              const SizedBox(height: T.s24),
              _Block(
                title: 'What typically does not count',
                icon: Icons.remove_circle_outline,
                tint: T.pastelPink,
                footnote:
                    'This is where people lose the most time — building '
                    'something that was never going to count.',
                child: EvidenceBullets(items: item.typicallyDoesNotCount),
              ),
            ],

            if (item.howToBuild.isNotEmpty) ...[
              const SizedBox(height: T.s24),
              _Block(
                title: 'How to build it if you do not have it',
                icon: Icons.construction_outlined,
                child: EvidenceBullets(items: item.howToBuild, marker: '→'),
              ),
            ],

            if (item.timeToBuild.isNotEmpty) ...[
              const SizedBox(height: T.s24),
              _Block(
                title: 'Roughly how long',
                icon: Icons.schedule_outlined,
                child: Text(
                  '${item.timeToBuild}\n\nA rough shape, not a promise — it '
                  'varies by field and by person.',
                  style: AppTheme.body,
                ),
              ),
            ],

            const SizedBox(height: T.s48),
            _SelfAssessment(item: item, service: service),

            const SizedBox(height: T.s32),
            _Pager(
              set: set,
              index: index,
              onGo: (target) => context.go('/evidence/$setId/${target.id}'),
            ),

            const SizedBox(height: T.s32),
            const EvidenceDisclaimer(compact: true),
          ],
        );
      },
    );
  }
}

/// Strength plus notes. There is no attachment control here and there never
/// will be — Lumos does not collect documents.
class _SelfAssessment extends StatefulWidget {
  const _SelfAssessment({required this.item, required this.service});

  final EvidenceItem item;
  final EvidenceService service;

  @override
  State<_SelfAssessment> createState() => _SelfAssessmentState();
}

class _SelfAssessmentState extends State<_SelfAssessment> {
  late final TextEditingController _notes = TextEditingController(
    text: widget.service.assessmentFor(widget.item.id).notes,
  );
  Timer? _debounce;
  bool _saved = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _notes.dispose();
    super.dispose();
  }

  void _onNotesChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      await widget.service.setNotes(widget.item.id, value);
      if (!mounted) return;
      setState(() => _saved = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strength = widget.service.strengthFor(widget.item.id);
    return Container(
      padding: const EdgeInsets.all(T.cardPadding),
      decoration: BoxDecoration(
        color: T.paper,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.fromBorderSide(T.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Where are you on this one?',
            style: AppTheme.headingSm.copyWith(fontSize: 19),
          ),
          const SizedBox(height: 6),
          Text(
            'Your own honest guess. Nobody is checking it, and it is not an '
            'eligibility decision — it shows the shape of your own record.',
            style: AppTheme.bodySm,
          ),
          const SizedBox(height: T.s24),
          EvidenceStrengthPicker(
            value: strength,
            onChanged: (value) {
              widget.service.setStrength(widget.item.id, value);
              setState(() => _saved = true);
            },
          ),
          const SizedBox(height: T.s24),
          Text(
            'Your notes',
            style: AppTheme.label.copyWith(
              color: T.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'What you have, who to ask, what you are waiting on. Whatever '
            'helps later.',
            style: AppTheme.caption,
          ),
          const SizedBox(height: T.s8),
          TextField(
            controller: _notes,
            onChanged: _onNotesChanged,
            maxLines: 5,
            minLines: 3,
            style: AppTheme.body.copyWith(color: T.ink),
            decoration: InputDecoration(
              hintText: 'Nothing yet is a fine answer.',
              hintStyle: AppTheme.body.copyWith(color: T.pencilGray),
              filled: true,
              fillColor: T.paper,
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
                borderSide: const BorderSide(color: T.signalBlue, width: 1.6),
              ),
            ),
          ),
          const SizedBox(height: T.s16),
          const EvidencePrivacyNote(),
          if (_saved) ...[
            const SizedBox(height: T.s8),
            Row(
              children: [
                const Icon(Icons.check, size: 14, color: T.signalBlue),
                const SizedBox(width: 6),
                Text(
                  'Saved in this browser',
                  style: AppTheme.caption.copyWith(color: T.signalBlue),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({
    required this.title,
    required this.icon,
    required this.child,
    this.tint,
    this.footnote,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Color? tint;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.cardPadding),
      decoration: BoxDecoration(
        color: tint?.withValues(alpha: 0.35) ?? T.paper,
        borderRadius: BorderRadius.circular(T.rCard),
        border: tint == null ? Border.fromBorderSide(T.hairline) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EvidenceSectionTitle(title, icon: icon),
          const SizedBox(height: T.s16),
          child,
          if (footnote != null) ...[
            const SizedBox(height: T.s8),
            Text(footnote!, style: AppTheme.caption),
          ],
        ],
      ),
    );
  }
}

/// One criterion per screen means there has to be a way forward that is not
/// "go back and pick the next one".
class _Pager extends StatelessWidget {
  const _Pager({required this.set, required this.index, required this.onGo});

  final EvidenceSet set;
  final int index;
  final ValueChanged<EvidenceItem> onGo;

  @override
  Widget build(BuildContext context) {
    final items = set.allItems;
    final previous = index > 0 ? items[index - 1] : null;
    final next = index >= 0 && index < items.length - 1
        ? items[index + 1]
        : null;

    return Row(
      children: [
        if (previous != null)
          Expanded(
            child: PillButton(
              label: 'Previous',
              icon: Icons.arrow_back,
              onPressed: () => onGo(previous),
            ),
          ),
        if (previous != null && next != null) const SizedBox(width: T.s16),
        if (next != null)
          Expanded(
            child: PillButton(
              label: 'Next criterion',
              variant: PillVariant.ink,
              trailingIcon: Icons.arrow_forward,
              onPressed: () => onGo(next),
            ),
          ),
      ],
    );
  }
}

class _BackLink extends StatelessWidget {
  const _BackLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.arrow_back, size: 15, color: T.graphite),
            const SizedBox(width: 8),
            Text('Back to $label', style: AppTheme.label),
          ],
        ),
      ),
    );
  }
}
