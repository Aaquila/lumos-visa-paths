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

  /// When on, hides "worth knowing" matches and shows only items that name
  /// the reader's own status, form or country. Client-side over whatever
  /// page is currently loaded — it doesn't change what the server fetches.
  bool _affectsYouOnly = false;

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
      return _publicFeed();
    }

    final result = await NewsService.instance.getNews(
      limit: _pageSize,
      offset: offset,
    );

    // The personalized feed failed (expired session, backend hiccup, etc).
    // Rather than block the page on an error, fall back to this year's
    // public updates — an empty result there just renders the empty state.
    if (result.error != null || result.offline) {
      return _publicFeed();
    }

    return result;
  }

  /// The public feed, trimmed to this year's updates, used whenever the
  /// personalized feed is unavailable.
  Future<PersonalisedNewsFeed> _publicFeed() async {
    final plain = await NewsService.instance.alerts();
    final thisYear = DateTime.now().year;
    final items = [
      for (final item in plain.items)
        if (item.date == null || item.date!.year == thisYear)
          NewsItemWithReadStatus(item: item, isRead: false),
    ];
    return PersonalisedNewsFeed(
      items: items,
      total: items.length,
      offline: plain.offline,
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

  /// Signed-in readers see unread articles first, newest within each group.
  /// Signed-out readers have no read status to group by, so the public feed
  /// is just newest to oldest.
  List<NewsItemWithReadStatus> _sortedItems() {
    final items = List.of(_allItems);
    items.sort((a, b) {
      if (_isAuthenticated && a.isRead != b.isRead) {
        return a.isRead ? 1 : -1;
      }
      final aDate = a.item.date;
      final bDate = b.item.date;
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return bDate.compareTo(aDate);
    });
    return items;
  }

  /// Sorted items, then narrowed to "affects you" when the filter is on.
  List<NewsItemWithReadStatus> _visibleItems() {
    final sorted = _sortedItems();
    if (!_affectsYouOnly) return sorted;
    return [
      for (final item in sorted)
        if (item.relevance == Relevance.affectsYou) item,
    ];
  }

  int get _affectsYouCount =>
      _allItems.where((i) => i.relevance == Relevance.affectsYou).length;

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
    final visible = _visibleItems();

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
        if (_isAuthenticated && _allItems.isNotEmpty) ...[
          _filterToggle(),
          const SizedBox(height: T.s16),
        ],
        if (_allItems.isEmpty)
          _Panel(
            child: Text(
              'No updates for your situation yet. Check back soon.',
              style: AppTheme.bodySm,
            ),
          )
        else if (visible.isEmpty)
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "None of what's loaded so far names your own status, "
                  'form or country directly.',
                  style: AppTheme.bodySm,
                ),
                const SizedBox(height: T.s8),
                PillButton(
                  label: 'Show all relevant updates',
                  onPressed: () => setState(() => _affectsYouOnly = false),
                ),
              ],
            ),
          )
        else ...[
          for (final item in visible)
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

  /// Toggles between the full personalized feed and "affects you" matches
  /// only — items that name the reader's own status, form or country, not
  /// just something adjacent to where they're headed.
  Widget _filterToggle() {
    return PillButton(
      label: _affectsYouOnly
          ? 'Affects you only ($_affectsYouCount)'
          : 'Show: all relevant',
      icon: Icons.filter_alt_outlined,
      variant: _affectsYouOnly ? PillVariant.signal : PillVariant.outline,
      onPressed: () => setState(() => _affectsYouOnly = !_affectsYouOnly),
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StepBadge(
          step: 'News',
          descriptor: _isAuthenticated
              ? 'personalized for you'
              : 'general updates',
        ),
        const SizedBox(height: T.s16),
        Text(
          _isAuthenticated
              ? 'Your personalized updates'
              : 'Latest immigration news',
          style: AppTheme.headingLg(context),
        ),
        const SizedBox(height: T.s8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Text(
            _isAuthenticated
                ? 'Rules, notices and alerts from USCIS, DHS, the State '
                      'Department and DOL. Unread articles appear first.'
                : 'Sign in and Lumos will show news personalized for your '
                      'situation. Until then, this is every update we '
                      'scrape from USCIS, DHS, the State Department and '
                      'DOL, sorted newest to oldest.',
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
