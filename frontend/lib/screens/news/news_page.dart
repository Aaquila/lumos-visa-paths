import 'package:flutter/material.dart';

import '../../models/news_item.dart';
import '../../services/auth_service.dart';
import '../../services/news_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/news_item_card.dart';
import '../../widgets/pill_button.dart';
import '../../widgets/site_footer.dart';
import '../../widgets/site_nav.dart';

/// `/news` — personalized policy updates with read status tracking.
///
/// Shows articles from the authenticated user's personalized feed:
/// - Unread articles appear first with a blue indicator
/// - Articles can be marked as read by opening them
/// - Infinite scroll loads next batch when scrolling near bottom
/// - Pull-to-refresh reloads the feed
/// - Falls back to public feed for unauthenticated users
class NewsPage extends StatefulWidget {
  const NewsPage({super.key, this.nodeId});

  /// Deep link: `/news?node=temp_worker.h1b` shows only updates matched to
  /// that status, chronologically.
  final String? nodeId;

  @override
  State<NewsPage> createState() => _NewsPageState();
}

class _NewsPageState extends State<NewsPage> {
  late ScrollController _scrollController;

  List<NewsItemWithReadStatus> _allItems = [];
  int _totalItems = 0;
  int _currentOffset = 0;
  final int _pageSize = 20;

  bool _isLoading = false;
  bool _isInitialLoading = true;
  bool _hasMoreItems = true;
  bool _isAuthenticated = false;
  String? _loadError;

  static const _fallbackDisclaimer =
      'Informational only, not legal advice. Every card links to the original '
      'document — read it before acting.';

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _isAuthenticated = AuthService.instance.session != null &&
        !AuthService.instance.session!.isDemo;
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Loads the initial page of articles.
  Future<void> _loadInitial() async {
    setState(() {
      _isInitialLoading = true;
      _loadError = null;
    });

    try {
      final result = await _fetchPage(0);

      if (mounted) {
        setState(() {
          _allItems = result.items;
          _totalItems = result.total;
          _currentOffset = 0;
          _hasMoreItems = result.items.length < result.total;
          _isInitialLoading = false;
          if (result.error != null) {
            _loadError = result.error;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitialLoading = false;
          _loadError = 'Failed to load articles';
        });
      }
    }
  }

  /// Fetches a page of articles from the API.
  Future<PersonalisedNewsFeed> _fetchPage(int offset) async {
    // Return public feed if not authenticated
    if (!_isAuthenticated) {
      final plain = await NewsService.instance.alerts();
      return PersonalisedNewsFeed(
        items: plain.items
            .map((item) => NewsItemWithReadStatus(item: item, isRead: false))
            .toList(),
        total: plain.total,
        offline: plain.offline,
      );
    }

    return await NewsService.instance.getNews(
      limit: _pageSize,
      offset: offset,
    );
  }

  /// Called when user scrolls near the bottom to load more items.
  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  /// Loads the next page of articles.
  Future<void> _loadMore() async {
    if (_isLoading || !_hasMoreItems || _allItems.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final nextOffset = _currentOffset + _pageSize;
      if (nextOffset >= _totalItems) {
        setState(() {
          _hasMoreItems = false;
          _isLoading = false;
        });
        return;
      }

      final result = await _fetchPage(nextOffset);

      if (mounted) {
        setState(() {
          _allItems.addAll(result.items);
          _currentOffset = nextOffset;
          _totalItems = result.total;
          _hasMoreItems = result.items.isNotEmpty &&
              (_currentOffset + _pageSize) < _totalItems;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to load more articles'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _loadMore,
            ),
          ),
        );
      }
    }
  }

  /// Pulls to refresh, reloads the feed.
  Future<void> _refresh() async {
    await NewsService.instance.refresh();
    if (!mounted) return;
    await _loadInitial();
  }

  /// Sorts articles by read status (unread first).
  List<NewsItemWithReadStatus> _sortedItems() {
    final items = List.of(_allItems);
    items.sort((a, b) {
      if (a.isRead == b.isRead) return 0;
      return a.isRead ? 1 : -1;
    });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final mobile = Breaks.isMobile(context);

    return Scaffold(
      backgroundColor: T.paper,
      body: Column(
        children: [
          const SiteNav(transparent: false, activeRoute: '/news'),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: mobile ? T.s24 : T.s32,
                        vertical: T.s48,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: T.pageMaxWidth,
                          ),
                          child: _buildContent(),
                        ),
                      ),
                    ),
                    const SiteFooter(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_isInitialLoading) {
      return _buildLoadingState();
    }

    if (_loadError != null && _allItems.isEmpty) {
      return _buildErrorState(_loadError!);
    }

    return _buildBody();
  }

  Widget _buildLoadingState() {
    return const Padding(
      padding: EdgeInsets.all(T.s48),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: T.s24),
        _Panel(
          fill: T.pastelSky,
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: T.graphite),
              const SizedBox(width: T.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      error,
                      style: AppTheme.bodySm,
                    ),
                    const SizedBox(height: T.s8),
                    PillButton(
                      label: 'Try again',
                      icon: Icons.refresh,
                      onPressed: _loadInitial,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: T.s24),
        if (_loadError != null && _allItems.isNotEmpty) ...[
          _Panel(
            fill: T.pastelSky,
            child: Row(
              children: [
                const Icon(Icons.warning_outlined, color: T.graphite),
                const SizedBox(width: T.s16),
                Expanded(
                  child: Text(_loadError!, style: AppTheme.bodySm),
                ),
              ],
            ),
          ),
          const SizedBox(height: T.s24),
        ],
        if (_allItems.isEmpty)
          _Panel(
            child: Text(
              'No updates for your situation yet. Check back soon.',
              style: AppTheme.bodySm,
            ),
          )
        else ...[
          for (final item in _sortedItems())
            Padding(
              padding: const EdgeInsets.only(bottom: T.s16),
              child: NewsItemCard(
                item: item,
                onReadStatusChanged: () => setState(() {}),
              ),
            ),
          if (_isLoading) ...[
            const SizedBox(height: T.s16),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            const SizedBox(height: T.s16),
          ] else if (_hasMoreItems) ...[
            const SizedBox(height: T.s8),
            PillButton(
              label: 'Load more',
              icon: Icons.arrow_downward,
              onPressed: _loadMore,
            ),
            const SizedBox(height: T.s16),
          ] else if (_allItems.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            Text(
              'No more articles',
              style: AppTheme.caption,
            ),
            const SizedBox(height: T.s16),
          ],
        ],
        const SizedBox(height: T.s40),
      ],
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StepBadge(
          step: 'News',
          descriptor: 'personalized for you',
        ),
        const SizedBox(height: T.s16),
        Text(
          'Your personalized updates',
          style: AppTheme.headingLg(context),
        ),
        const SizedBox(height: T.s8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Text(
            'Rules, notices and alerts from USCIS, DHS, the State Department '
            'and DOL. Unread articles appear first.',
            style: AppTheme.body,
          ),
        ),
        const SizedBox(height: T.s8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Text(
            _fallbackDisclaimer,
            style: AppTheme.caption,
          ),
        ),
      ],
    );
  }
}

/// A bordered block. Reusable container style.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.fill,
  });

  final Widget child;
  final Color? fill;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(T.s24),
    decoration: BoxDecoration(
      color: fill ?? T.paper,
      border: Border.all(color: T.pencilGray),
      borderRadius: BorderRadius.circular(T.rCard),
    ),
    child: child,
  );
}
