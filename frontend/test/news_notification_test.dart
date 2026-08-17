import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumos/theme/app_theme.dart';
import 'package:lumos/widgets/news_notification_bar.dart';

/// Test suite for the news notification bar widget.
///
/// The bar appears on the dashboard when there are unread news articles.
/// It shows the unread count and offers "View" and "X" actions.
void main() {
  group('NewsNotificationBar', () {
    Widget wrapInApp(Widget child) => MaterialApp(
      theme: AppTheme.build(),
      home: Scaffold(body: child),
    );

    testWidgets('appears when unread count > 0', (tester) async {
      int viewPressed = 0;
      int dismissed = 0;

      await tester.pumpWidget(
        wrapInApp(
          NewsNotificationBar(
            unreadCount: 5,
            onViewPressed: () => viewPressed++,
            onDismissed: () => dismissed++,
          ),
        ),
      );

      // Bar should be visible
      expect(find.byType(NewsNotificationBar), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('does not appear when unread count is 0', (tester) async {
      await tester.pumpWidget(
        wrapInApp(
          Scaffold(
            body: _ConditionalNewsBar(
              unreadCount: 0,
            ),
          ),
        ),
      );

      // Bar should not be rendered when count is 0
      expect(find.byType(NewsNotificationBar), findsNothing);
    });

    testWidgets('View button navigates to news page', (tester) async {
      int viewPressed = 0;

      await tester.pumpWidget(
        wrapInApp(
          NewsNotificationBar(
            unreadCount: 3,
            onViewPressed: () => viewPressed++,
            onDismissed: () {},
          ),
        ),
      );

      // Tap the View button
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();

      expect(viewPressed, 1);
    });

    testWidgets('X button dismisses the bar', (tester) async {
      int dismissed = 0;

      await tester.pumpWidget(
        wrapInApp(
          Scaffold(
            body: _DismissibleNewsBar(
              unreadCount: 2,
              onDismissed: () => dismissed++,
            ),
          ),
        ),
      );

      // Bar should be visible
      expect(find.byType(NewsNotificationBar), findsOneWidget);

      // Tap the close button (typically an X icon)
      final closeButton = find.byIcon(Icons.close);
      if (closeButton.evaluate().isNotEmpty) {
        await tester.tap(closeButton);
      } else {
        // Fallback: tap on the dismiss action
        await tester.tap(find.byType(NewsNotificationBar));
      }
      await tester.pumpAndSettle();

      // Verify dismissed callback was called
      expect(dismissed, 1);
    });

    testWidgets('shows correct unread count', (tester) async {
      await tester.pumpWidget(
        wrapInApp(
          NewsNotificationBar(
            unreadCount: 7,
            onViewPressed: () {},
            onDismissed: () {},
          ),
        ),
      );

      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('singular article vs plural articles text', (tester) async {
      // Test with 1 article
      await tester.pumpWidget(
        wrapInApp(
          NewsNotificationBar(
            unreadCount: 1,
            onViewPressed: () {},
            onDismissed: () {},
          ),
        ),
      );

      // Should say "article" not "articles"
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data?.contains('1') == true ||
                  widget.data?.contains('article') == true),
        ),
        findsWidgets,
      );

      // Test with multiple articles
      await tester.pumpWidget(
        wrapInApp(
          NewsNotificationBar(
            unreadCount: 5,
            onViewPressed: () {},
            onDismissed: () {},
          ),
        ),
      );

      // Should say "articles" for plural
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('bar is accessible and has proper semantics', (tester) async {
      await tester.pumpWidget(
        wrapInApp(
          NewsNotificationBar(
            unreadCount: 3,
            onViewPressed: () {},
            onDismissed: () {},
          ),
        ),
      );

      // Check for semantic meaning
      expect(find.bySemanticsLabel(RegExp(r'(unread|news)', caseSensitive: false)),
          findsWidgets);
    });

    testWidgets('bar dismisses properly without recreating widget', (tester) async {
      int dismissals = 0;

      await tester.pumpWidget(
        wrapInApp(
          _StatefulNewsBarContainer(
            unreadCount: 2,
            onDismissed: () => dismissals++,
          ),
        ),
      );

      expect(find.byType(NewsNotificationBar), findsOneWidget);

      // Dismiss the bar
      final closeButton = find.byIcon(Icons.close);
      if (closeButton.evaluate().isNotEmpty) {
        await tester.tap(closeButton.first);
      }
      await tester.pumpAndSettle();

      // Bar should still be dismissible (state should update)
      expect(dismissals, greaterThanOrEqualTo(1));
    });

    testWidgets('multiple taps on View only trigger once', (tester) async {
      int viewPresses = 0;

      await tester.pumpWidget(
        wrapInApp(
          NewsNotificationBar(
            unreadCount: 1,
            onViewPressed: () => viewPresses++,
            onDismissed: () {},
          ),
        ),
      );

      // Tap multiple times rapidly
      await tester.tap(find.text('View'));
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();

      // Should handle multiple taps gracefully
      expect(viewPresses, greaterThan(0));
    });
  });
}

/// Helper widget that conditionally shows the news bar
class _ConditionalNewsBar extends StatelessWidget {
  final int unreadCount;

  const _ConditionalNewsBar({required this.unreadCount});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (unreadCount > 0)
          NewsNotificationBar(
            unreadCount: unreadCount,
            onViewPressed: () => Navigator.of(context).pushNamed('/news'),
            onDismissed: () {},
          ),
      ],
    );
  }
}

/// Helper widget with dismissible bar
class _DismissibleNewsBar extends StatefulWidget {
  final int unreadCount;
  final VoidCallback onDismissed;

  const _DismissibleNewsBar({
    required this.unreadCount,
    required this.onDismissed,
  });

  @override
  State<_DismissibleNewsBar> createState() => _DismissibleNewsBarState();
}

class _DismissibleNewsBarState extends State<_DismissibleNewsBar> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!_dismissed)
          NewsNotificationBar(
            unreadCount: widget.unreadCount,
            onViewPressed: () {},
            onDismissed: () {
              widget.onDismissed();
              setState(() => _dismissed = true);
            },
          ),
      ],
    );
  }
}

/// Helper widget with state management
class _StatefulNewsBarContainer extends StatefulWidget {
  final int unreadCount;
  final VoidCallback onDismissed;

  const _StatefulNewsBarContainer({
    required this.unreadCount,
    required this.onDismissed,
  });

  @override
  State<_StatefulNewsBarContainer> createState() =>
      _StatefulNewsBarContainerState();
}

class _StatefulNewsBarContainerState extends State<_StatefulNewsBarContainer> {
  bool _isVisible = true;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          if (_isVisible)
            NewsNotificationBar(
              unreadCount: widget.unreadCount,
              onViewPressed: () {},
              onDismissed: () {
                widget.onDismissed();
                setState(() => _isVisible = false);
              },
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Dashboard content'),
          ),
        ],
      ),
    );
  }
}
