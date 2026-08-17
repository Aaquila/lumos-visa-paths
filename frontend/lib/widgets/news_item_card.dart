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
/// - Shows title, summary, source, published date
/// - Blue "NEW" badge for unread articles
/// - Tapping opens original link in browser
/// - Tapping also marks article as read via API
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

  /// Opens the article URL and marks it as read.
  Future<void> _handleTap() async {
    // Open the URL first (doesn't block for user)
    await _openUrl(widget.item.item.url);

    // Then mark as read if not already marked
    if (!_isRead) {
      await _markAsRead();
    }
  }

  /// Opens the original article URL in the browser.
  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
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
                  // Title
                  Text(
                    article.title,
                    style: AppTheme.bodySm.copyWith(
                      color: T.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),

                  // Summary (if available)
                  if (article.summary.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      article.summary,
                      style: AppTheme.bodySm,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],

                  // Footer with source, date, and link
                  const SizedBox(height: T.s16),
                  _CardFooter(item: article),
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

/// Footer showing source, document type, date, and link icon.
class _CardFooter extends StatelessWidget {
  const _CardFooter({required this.item});

  final NewsItem item;

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
        Row(
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
      ],
    );
  }
}
