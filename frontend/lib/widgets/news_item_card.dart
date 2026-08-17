import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/news_item.dart';
import '../services/news_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'badges.dart';

/// A card displaying a single news article with read status tracking.
///
/// Features:
/// - When Claude has generated one, a personalized "what this means for you"
///   headline leads the card — larger than the article's own title, which
///   becomes a muted subtitle beneath it — followed by Claude's plain-language
///   explanation and, separately, the article's own raw summary
/// - Blue "NEW" badge for unread articles
/// - Tapping the card expands it in place to show all of the above in full
///   and marks it as read; tapping "Read the original" is the only thing
///   that leaves the app, opening the source document in the browser
/// - Shows loading state while marking as read
class NewsItemCard extends StatefulWidget {
  const NewsItemCard({
    super.key,
    required this.item,
    required this.onReadStatusChanged,
  });

  /// The news article to display with its read status.
  final NewsItemWithReadStatus item;

  /// Callback when read status changes. Allows parent to resort list.
  final VoidCallback onReadStatusChanged;

  @override
  State<NewsItemCard> createState() => _NewsItemCardState();
}

class _NewsItemCardState extends State<NewsItemCard> {
  late bool _isRead = widget.item.isRead;
  bool _isMarking = false;
  bool _expanded = false;

  /// Expands the card and marks it as read — viewing the summary counts as
  /// reading it. Opening the original document is a separate, explicit tap.
  void _handleTap() {
    setState(() => _expanded = !_expanded);
    if (_expanded && !_isRead) {
      _markAsRead();
    }
  }

  /// Opens the original article URL in the browser. This is the only action
  /// that navigates away from the app.
  Future<void> _openOriginal() async {
    if (!_isRead) {
      await _markAsRead();
    }
    final uri = Uri.tryParse(widget.item.item.url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open link: $e')),
        );
      }
    }
  }

  /// Marks the article as read via API and updates UI.
  Future<void> _markAsRead() async {
    if (_isRead || _isMarking) return;

    setState(() => _isMarking = true);

    try {
      final success = await NewsService.instance.markArticleAsRead(
        widget.item.item.id,
      );

      if (mounted) {
        setState(() {
          if (success) {
            _isRead = true;
            widget.onReadStatusChanged();
          }
          _isMarking = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isMarking = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to mark as read: $e'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _markAsRead,
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.item.item;
    final headline = widget.item.personalizedHeadline;
    final hasHeadline = headline != null && headline.isNotEmpty;
    final personalizedSummary = widget.item.personalizedSummary;
    final hasPersonalizedSummary =
        personalizedSummary != null && personalizedSummary.isNotEmpty;
    final notRelevant = widget.item.isMarkedNotRelevant;
    final hasExpandableContent = hasPersonalizedSummary || article.summary.isNotEmpty;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _isMarking ? null : _handleTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(T.s24),
          decoration: BoxDecoration(
            color: T.paper,
            border: Border.all(
              color: _isRead ? T.pencilGray : T.signalBlue,
              width: _isRead ? 1 : 2,
            ),
            borderRadius: BorderRadius.circular(T.rCard),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Personalized headline — "what this means for you" — is the
                  // primary heading whenever Claude has written one, larger
                  // than the article's own title, which drops to a subtitle
                  // beneath it. Muted (not the sparkle) when Claude judged the
                  // article doesn't touch this reader's situation.
                  if (hasHeadline) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          notRelevant
                              ? Icons.remove_circle_outline
                              : Icons.auto_awesome,
                          size: 16,
                          color: notRelevant ? T.pencilGray : T.signalBlue,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            headline,
                            style: AppTheme.bodySm.copyWith(
                              color: notRelevant ? T.graphite : T.ink,
                              fontWeight: FontWeight.w700,
                              fontSize: 19,
                              height: 1.25,
                            ),
                            maxLines: _expanded ? null : 3,
                            overflow: _expanded
                                ? TextOverflow.visible
                                : TextOverflow.ellipsis,
                          ),
                        ),
                        if (hasExpandableContent) ...[
                          const SizedBox(width: 8),
                          Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            size: 20,
                            color: T.pencilGray,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],

                  // The article's own title — the main heading when there's
                  // no personalized headline yet; a muted subtitle beneath it
                  // otherwise.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          article.title,
                          style: hasHeadline
                              ? AppTheme.caption.copyWith(
                                  fontWeight: FontWeight.w500,
                                )
                              : AppTheme.bodySm.copyWith(
                                  color: T.ink,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                          maxLines: _expanded ? null : 3,
                          overflow: _expanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                        ),
                      ),
                      if (!hasHeadline && hasExpandableContent) ...[
                        const SizedBox(width: 8),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: T.pencilGray,
                        ),
                      ],
                    ],
                  ),

                  // Personalized explanation — the reasoning behind the
                  // headline above. Distinct from the article's own summary
                  // below: this is Claude's plain-language read for this
                  // reader specifically.
                  if (hasPersonalizedSummary) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Personalized for you',
                      style: AppTheme.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: notRelevant ? T.graphite : T.signalBlue,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      personalizedSummary,
                      style: AppTheme.bodySm,
                      maxLines: _expanded ? null : 3,
                      overflow: _expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                    ),
                  ],

                  // The article's own summary — raw scraped text, kept
                  // separate from the personalized explanation above so
                  // readers can tell Claude's read apart from the source.
                  if (article.summary.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Article summary',
                      style: AppTheme.caption.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      article.summary,
                      style: AppTheme.bodySm,
                      maxLines: _expanded ? null : 2,
                      overflow: _expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                    ),
                  ],

                  // Footer with source, date, and link
                  const SizedBox(height: T.s16),
                  _CardFooter(item: article, onOpenOriginal: _openOriginal),
                ],
              ),

              // Unread indicator in top-right corner
              if (!_isRead)
                Positioned(
                  top: 0,
                  right: 0,
                  child: _isMarking
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              T.signalBlue,
                            ),
                          ),
                        )
                      : Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: T.signalBlue,
                            shape: BoxShape.circle,
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

/// Footer showing source, document type, date, and a link to the original
/// document — the only tappable element in the card that leaves the app.
class _CardFooter extends StatelessWidget {
  const _CardFooter({required this.item, required this.onOpenOriginal});

  final NewsItem item;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    final date = item.date?.toLocal();
    final type = item.meta.documentType;

    return Wrap(
      spacing: T.s8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(item.sourceName, style: AppTheme.caption),
        if (type.isNotEmpty) MetaPill(label: type, iconColor: T.pencilGray),
        if (date != null)
          Text(
            '${date.year}-${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}',
            style: AppTheme.caption,
          ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            // Consumes the tap here so the parent card's onTap (expand)
            // doesn't also fire — this is the only element that navigates.
            onTap: onOpenOriginal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.open_in_new, size: 12, color: T.signalBlue),
                const SizedBox(width: 4),
                Text(
                  'Read the original',
                  style: AppTheme.caption.copyWith(color: T.signalBlue),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
