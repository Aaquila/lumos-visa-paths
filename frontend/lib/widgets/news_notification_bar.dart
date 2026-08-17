import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'pill_button.dart';

/// A notification bar that appears at the top of the dashboard when there are
/// unread news articles.
///
/// Shows "You have X new updates relevant to you" with:
/// - "View" button to navigate to news page
/// - "X" button to dismiss the bar
/// - Blue accent color
/// - Animated entrance (fade in from top)
/// - Auto-fade after 8 seconds of inactivity (optional)
class NewsNotificationBar extends StatefulWidget {
  const NewsNotificationBar({
    super.key,
    required this.unreadCount,
    required this.onViewPressed,
    required this.onDismissed,
  });

  /// Number of unread news articles
  final int unreadCount;

  /// Callback when user clicks "View"
  final VoidCallback onViewPressed;

  /// Callback when user dismisses the bar
  final VoidCallback onDismissed;

  @override
  State<NewsNotificationBar> createState() => _NewsNotificationBarState();
}

class _NewsNotificationBarState extends State<NewsNotificationBar>
    with TickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;
  bool _isDismissed = false;

  @override
  void initState() {
    super.initState();

    // Fade in animation
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOut),
    );

    // Start fade in
    _fadeController.forward();

    // Auto-dismiss after 8 seconds if not interacted with
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted && !_isDismissed) {
        _dismiss();
      }
    });
  }

  void _dismiss() {
    setState(() => _isDismissed = true);
    _fadeController.reverse().then((_) {
      if (mounted) {
        widget.onDismissed();
      }
    });
  }

  void _onViewPressed() {
    setState(() => _isDismissed = true);
    _fadeController.reverse().then((_) {
      if (mounted) {
        widget.onViewPressed();
      }
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.of(context).disableAnimations;

    return FadeTransition(
      opacity: reduced ? AlwaysStoppedAnimation(1.0) : _fadeAnimation,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: T.s24,
          vertical: T.s16,
        ),
        decoration: BoxDecoration(
          color: T.pastelSky,
          border: Border(
            bottom: BorderSide(color: T.signalBlue, width: 2),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Icon
            const Padding(
              padding: EdgeInsets.only(right: T.s8),
              child: Icon(
                Icons.notifications_active_outlined,
                color: T.signalBlue,
                size: 20,
              ),
            ),

            // Message
            Expanded(
              child: Text(
                'You have ${widget.unreadCount} new update${widget.unreadCount != 1 ? 's' : ''} relevant to you',
                style: AppTheme.bodySm.copyWith(
                  color: T.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            const SizedBox(width: T.s16),

            // View button
            PillButton(
              label: 'View',
              icon: Icons.arrow_forward,
              onPressed: _onViewPressed,
            ),

            const SizedBox(width: T.s8),

            // Dismiss button (X)
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: _dismiss,
                padding: EdgeInsets.zero,
                tooltip: 'Dismiss',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
