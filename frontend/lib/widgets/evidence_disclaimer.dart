import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The legal disclaimer. Shown on every evidence screen, near the top, because
/// this is a product about immigration law and burying it would be the wrong
/// call twice over.
class EvidenceDisclaimer extends StatelessWidget {
  const EvidenceDisclaimer({super.key, this.text, this.compact = false});

  /// Overrides the default with the wording from the reference data.
  final String? text;
  final bool compact;

  static const _fallback =
      'This is general information, not legal advice. It describes what USCIS '
      'generally looks for — it does not predict any particular decision. '
      'Adjudication is discretionary and outcomes vary between cases that look '
      'alike on paper. O-1 and EB-1 petitions are usually worth reviewing with '
      'an immigration attorney before filing.';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? T.s16 : T.s24),
      decoration: BoxDecoration(
        color: T.pastelYellow.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.balance_outlined, size: 18, color: T.carbon),
          const SizedBox(width: T.s16),
          Expanded(
            child: Text(
              text ?? _fallback,
              style: AppTheme.bodySm.copyWith(color: T.carbon),
            ),
          ),
        ],
      ),
    );
  }
}

/// The privacy promise, stated where the user is being asked to type about
/// themselves. It also states the thing Lumos will never ask for, so nobody
/// goes looking for an upload button that does not exist.
class EvidencePrivacyNote extends StatelessWidget {
  const EvidencePrivacyNote({super.key, this.text});

  final String? text;

  static const _fallback =
      'Everything you record here stays in this browser. Nothing is uploaded, '
      'and Lumos never asks for documents — only your own assessment and your '
      'own notes.';

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.lock_outline, size: 16, color: T.pencilGray),
        const SizedBox(width: 10),
        Expanded(child: Text(text ?? _fallback, style: AppTheme.caption)),
      ],
    );
  }
}

/// Used where the reference data itself says it is unsure. Saying so is better
/// than guessing.
class EvidenceUncertaintyNote extends StatelessWidget {
  const EvidenceUncertaintyNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(T.rInput),
        border: Border.fromBorderSide(T.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.help_outline, size: 16, color: T.graphite),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Where we are not certain: $text',
              style: AppTheme.bodySm,
            ),
          ),
        ],
      ),
    );
  }
}
