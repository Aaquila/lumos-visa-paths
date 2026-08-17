import 'package:flutter/material.dart';

import '../../services/evidence_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/site_footer.dart';
import '../../widgets/site_nav.dart';

/// The page shell every evidence screen shares: nav, one narrow column, footer.
///
/// The column is deliberately narrower than the rest of the site. These screens
/// are long-form reading, and a short measure is the cheapest accessibility win
/// available.
class EvidenceScaffold extends StatelessWidget {
  const EvidenceScaffold({
    super.key,
    required this.children,
    this.maxWidth = 760,
  });

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final compact = Breaks.isMobile(context);
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SiteNav(transparent: false),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? T.s16 : T.s32,
                vertical: compact ? T.s32 : T.s48,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: children,
                  ),
                ),
              ),
            ),
            const SiteFooter(),
          ],
        ),
      ),
    );
  }
}

/// Loads the criteria file and the stored self-assessment once, then rebuilds
/// on every change to either.
class EvidenceLoader extends StatefulWidget {
  const EvidenceLoader({super.key, required this.builder});

  final Widget Function(BuildContext context, EvidenceService service) builder;

  @override
  State<EvidenceLoader> createState() => _EvidenceLoaderState();
}

class _EvidenceLoaderState extends State<EvidenceLoader> {
  late final Future<void> _ready = EvidenceService.instance.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const EvidenceScaffold(
            children: [
              SizedBox(height: T.s48),
              Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          );
        }
        if (snapshot.hasError || EvidenceService.instance.catalog == null) {
          return EvidenceScaffold(
            children: [
              Text(
                'The criteria reference could not be loaded.',
                style: AppTheme.headingSm,
              ),
              const SizedBox(height: T.s8),
              Text(
                'Nothing you recorded is affected — it is stored in this '
                'browser. Reloading usually fixes this.',
                style: AppTheme.body,
              ),
            ],
          );
        }
        return AnimatedBuilder(
          animation: EvidenceService.instance,
          builder: (context, _) =>
              widget.builder(context, EvidenceService.instance),
        );
      },
    );
  }
}

/// A short, quiet section heading. Used everywhere instead of long legal
/// headers.
class EvidenceSectionTitle extends StatelessWidget {
  const EvidenceSectionTitle(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: T.graphite),
          const SizedBox(width: 8),
        ],
        Text(
          text,
          style: AppTheme.label.copyWith(
            color: T.ink,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ],
    );
  }
}

/// A bulleted list, chunked short. Long legal prose is broken into these
/// rather than left as a paragraph nobody finishes.
class EvidenceBullets extends StatelessWidget {
  const EvidenceBullets({
    super.key,
    required this.items,
    this.marker = '·',
    this.color = T.graphite,
  });

  final List<String> items;
  final String marker;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: 10),
                  child: Text(
                    marker,
                    style: AppTheme.body.copyWith(color: color),
                  ),
                ),
                Expanded(child: Text(item, style: AppTheme.body)),
              ],
            ),
          ),
      ],
    );
  }
}
