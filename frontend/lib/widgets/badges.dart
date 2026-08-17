import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// `STEP 1 · AI SITEMAP`-style section label: pill hairline, bold ink segment,
/// dot separator, muted descriptor.
class StepBadge extends StatelessWidget {
  const StepBadge({super.key, required this.step, required this.descriptor});

  final String step;
  final String descriptor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rPill),
      ),
      // One label, not three fragments: "WHY THIS EXISTS · THE HONEST VERSION"
      // read out as three separate nodes (including a lone middot) is noise.
      child: Semantics(
        label: '$step, $descriptor',
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(step.toUpperCase(), style: AppTheme.badge),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '·',
                  style: AppTheme.badge.copyWith(color: T.graphite),
                ),
              ),
              Flexible(
                child: Text(
                  descriptor.toUpperCase(),
                  style: AppTheme.badge.copyWith(
                    fontWeight: FontWeight.w400,
                    // Graphite (5.13:1), not Pencil Gray (2.84:1) — this is
                    // 11px text and has to clear the body-text bar.
                    color: T.graphite,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 32px pastel circle with a 1.5px dark icon — used inline to punctuate copy.
class PastelIconBadge extends StatelessWidget {
  const PastelIconBadge({
    super.key,
    required this.icon,
    required this.fill,
    this.size = 32,
    this.semanticLabel,
  });

  final IconData icon;
  final Color fill;
  final double size;

  /// Left null — the default — the badge is treated as pure decoration and
  /// dropped from the reading order, because it always sits directly beside the
  /// heading it punctuates. Pass a label only where the badge is the *only*
  /// carrier of some meaning.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.5, color: T.ink),
    );
    return semanticLabel == null
        ? ExcludeSemantics(child: badge)
        : Semantics(label: semanticLabel, image: true, child: badge);
  }
}

/// Small hairline pill used for social proof and inline metadata.
class MetaPill extends StatelessWidget {
  const MetaPill({
    super.key,
    required this.label,
    this.icon,
    this.iconColor = T.signalBlue,
  });

  final String label;
  final IconData? icon;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: T.paper,
        border: Border.fromBorderSide(T.hairline),
        borderRadius: BorderRadius.circular(T.rPill),
      ),
      child: MergeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              ExcludeSemantics(child: Icon(icon, size: 13, color: iconColor)),
              const SizedBox(width: 6),
            ],
            // Flexible, not fixed: long labels ("Optional step — can be
            // skipped") and enlarged browser font sizes both overflow a rigid
            // Row. Wrapping is the right failure mode for a pill; clipping the
            // words is not.
            Flexible(
              child: Text(
                label,
                style: AppTheme.caption.copyWith(
                  color: T.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
