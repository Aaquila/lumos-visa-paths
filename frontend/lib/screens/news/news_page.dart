import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/news_item.dart';
import '../../services/auth_service.dart';
import '../../services/news_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
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

  /// Toggle between 'personalized' (Claude-generated summaries) and 'generic'
  /// (raw articles for all users). Authenticated users see both options;
  /// unauthenticated users only see generic.
  String _viewMode = 'personalized';

  /// True while regenerating personalized summaries after visa status change.
  bool _isRegeneratingPersonalization = false;

  /// The ID token seen at last check. A restored session (any reload, any
  /// new tab within the 14-day "stay signed in" window) comes back from
  /// storage `isSignedIn` but with no token — Google's ID token is
  /// deliberately never persisted — so the very first personalized fetch
  /// almost always 401s and silently falls back to the public feed before
  /// [AuthService]'s background silent re-auth has had time to land. Tracking
  /// this lets [_onAuthChanged] tell "still no token" apart from "a token
  /// just arrived" and re-fetch only on the latter, instead of re-fetching on
  /// every unrelated [AuthService] notification (onboarding edits, etc).
  String? _lastAuthToken;

  static const _fallbackDisclaimer =
      'Informational only, not legal advice. Every card links to the original '
      'document — read it before acting.';

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _isAuthenticated =
        AuthService.instance.session != null &&
        !AuthService.instance.session!.isDemo;
    _lastAuthToken = AuthService.instance.apiToken;
    AuthService.instance.addListener(_onAuthChanged);
    _loadInitial();
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// Re-fetches once a usable token shows up — the sign-in token exchange
  /// (`POST /api/auth/session`) completes a beat after the session itself
  /// lands. Without this, a page opened in that beat stays on the public
  /// fallback feed for the rest of the visit.
  void _onAuthChanged() {
    final session = AuthService.instance.session;
    _isAuthenticated = session != null && !session.isDemo;

    final token = AuthService.instance.apiToken;
    if (token != null && token.isNotEmpty && token != _lastAuthToken) {
      _lastAuthToken = token;
      _loadInitial(forceRefresh: true);
    } else {
      _lastAuthToken = token;
    }
  }

  /// Loads the initial page of articles.
  Future<void> _loadInitial({bool forceRefresh = false}) async {
    setState(() {
      _isInitialLoading = true;
      _loadError = null;
    });

    try {
      final result = await _fetchPage(0, forceRefresh: forceRefresh);

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
  ///
  /// If in generic view mode, always fetches public feed (all users).
  /// If in personalized view mode and authenticated, fetches personalized feed
  /// with Claude-generated summaries. Shows error state if it fails.
  Future<PersonalisedNewsFeed> _fetchPage(
    int offset, {
    bool forceRefresh = false,
  }) async {
    // Unauthenticated or viewing generic news — show public feed
    if (!_isAuthenticated || _viewMode == 'generic') {
      return _publicFeed();
    }

    // Personalized view for authenticated user
    final result = await NewsService.instance.getNews(
      limit: _pageSize,
      offset: offset,
      forceRefresh: forceRefresh,
    );

    // Return the result as-is (including any errors) to show error state
    // instead of silently falling back to public feed
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
          _hasMoreItems =
              result.items.isNotEmpty &&
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
            action: SnackBarAction(label: 'Retry', onPressed: _loadMore),
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
          child: CircularProgressIndicator(strokeWidth: 2),
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
                    Text(error, style: AppTheme.bodySm),
                    const SizedBox(height: T.s8),
                    // Retrying is only worth offering when a retry could
                    // succeed. With no credential the backend accepts, every
                    // "try again" is another 401 — the way out is the sign-in
                    // screen, so say that instead.
                    if (AuthService.instance.needsReauth)
                      PillButton(
                        label: 'Sign in again',
                        icon: Icons.login,
                        onPressed: () => context.go('/signin'),
                      )
                    else
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
                Expanded(child: Text(_loadError!, style: AppTheme.bodySm)),
              ],
            ),
          ),
          const SizedBox(height: T.s24),
        ],

        // "Affects you only" filter (personalized view only)
        if (_isAuthenticated &&
            _viewMode == 'personalized' &&
            _allItems.isNotEmpty) ...[
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
            Text('No more articles', style: AppTheme.caption),
            const SizedBox(height: T.s16),
          ],
        ],

        // Regenerate button (personalized view only)
        _buildRegenerateButton(),

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

  /// Regenerates personalized summaries for all articles.
  ///
  /// Called when user updates their visa situation/status. Clears existing
  /// personalized headlines and summaries, then regenerates them based on
  /// the user's current situation.
  Future<void> _regeneratePersonalization() async {
    if (!_isAuthenticated) return;

    setState(() => _isRegeneratingPersonalization = true);

    try {
      final success = await NewsService.instance.regeneratePersonalization();

      if (success && mounted) {
        // Reload with freshly generated summaries
        await _loadInitial(forceRefresh: true);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Personalization regenerated! Your news is up to date.',
              ),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to regenerate personalization.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isRegeneratingPersonalization = false);
      }
    }
  }

  /// "Redo Personalization" button shown in personalized view.
  ///
  /// Appears when user may have updated their visa status and wants to
  /// regenerate personalized summaries based on the new information.
  Widget _buildRegenerateButton() {
    if (_viewMode != 'personalized' || !_isAuthenticated) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: T.s16),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            PillButton(
              label: _isRegeneratingPersonalization
                  ? 'Regenerating...'
                  : 'Redo Personalization',
              icon: Icons.refresh,
              variant: PillVariant.signal,
              onPressed: _isRegeneratingPersonalization
                  ? null
                  : _regeneratePersonalization,
            ),
            Text(
              "Use this if you've updated your visa status",
              style: AppTheme.caption,
            ),
          ],
        ),
      ],
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            PillButton(
              label: 'NEWS · GENERAL UPDATES',
              variant: _viewMode == 'generic'
                  ? PillVariant.signal
                  : PillVariant.outline,
              onPressed: () => setState(() {
                _viewMode = 'generic';
                _loadInitial(forceRefresh: true);
              }),
            ),
            const SizedBox(width: T.s8),
            PillButton(
              label: _isAuthenticated
                  ? 'PERSONALIZED'
                  : 'SIGN IN FOR PERSONALIZED',
              variant: _viewMode == 'personalized' && _isAuthenticated
                  ? PillVariant.signal
                  : PillVariant.outline,
              onPressed: _isAuthenticated
                  ? () => setState(() {
                      _viewMode = 'personalized';
                      _loadInitial(forceRefresh: true);
                    })
                  : () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Sign in to see personalized news updates for your visa situation.',
                          ),
                          duration: Duration(seconds: 3),
                        ),
                      );
                    },
            ),
          ],
        ),
        const SizedBox(height: T.s24),
        Text(
          _isAuthenticated
              ? _viewMode == 'personalized'
                    ? 'Your personalized updates'
                    : 'Latest immigration news'
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
          child: Text(_fallbackDisclaimer, style: AppTheme.caption),
        ),
      ],
    );
  }
}

/// A bordered block. Reusable container style.
class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.fill});

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
