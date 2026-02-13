// ABOUTME: Reusable BlocListener that tracks Firebase analytics for explore
// ABOUTME: feed tabs. Wraps any ExploreFeedBloc subclass via generic type.

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:openvine/blocs/explore_feed/explore_feed_bloc.dart';
import 'package:openvine/services/error_analytics_tracker.dart';
import 'package:openvine/services/feed_performance_tracker.dart';
import 'package:openvine/services/screen_analytics_service.dart';

/// Listens to [ExploreFeedBloc] state changes and fires Firebase analytics.
///
/// Wrap any explore tab's content with this widget to restore feed performance
/// tracking, error tracking, and screen-load metrics without polluting the
/// UI code.
///
/// ```dart
/// ExploreFeedAnalyticsListener<NewVideosFeedBloc>(
///   feedType: 'new_vines',
///   child: BlocBuilder<NewVideosFeedBloc, ExploreFeedState>(...),
/// )
/// ```
class ExploreFeedAnalyticsListener<B extends ExploreFeedBloc>
    extends StatefulWidget {
  const ExploreFeedAnalyticsListener({
    required this.feedType,
    required this.child,
    super.key,
  });

  /// Identifier used in analytics events (e.g. `'new_vines'`, `'popular'`).
  final String feedType;

  final Widget child;

  @override
  State<ExploreFeedAnalyticsListener<B>> createState() =>
      _ExploreFeedAnalyticsListenerState<B>();
}

class _ExploreFeedAnalyticsListenerState<B extends ExploreFeedBloc>
    extends State<ExploreFeedAnalyticsListener<B>> {
  final _feedTracker = FeedPerformanceTracker();
  final _screenAnalytics = ScreenAnalyticsService();
  final _errorTracker = ErrorAnalyticsTracker();

  DateTime? _loadStartTime;

  @override
  Widget build(BuildContext context) {
    return BlocListener<B, ExploreFeedState>(
      listener: _onStateChanged,
      child: widget.child,
    );
  }

  void _onStateChanged(BuildContext context, ExploreFeedState state) {
    switch (state.status) {
      case ExploreFeedStatus.initial:
        break;
      case ExploreFeedStatus.loading:
        _loadStartTime = DateTime.now();
        _feedTracker.startFeedLoad(widget.feedType);
      case ExploreFeedStatus.success:
        if (state.videos.isEmpty) {
          _feedTracker.trackEmptyFeed(widget.feedType);
        } else {
          _feedTracker.markFirstVideosReceived(
            widget.feedType,
            state.videos.length,
          );
          _feedTracker.markFeedDisplayed(widget.feedType, state.videos.length);
          _screenAnalytics.markDataLoaded(
            'explore_screen',
            dataMetrics: {
              'tab': widget.feedType,
              'video_count': state.videos.length,
            },
          );
        }
        _trackSlowOperationIfNeeded();
      case ExploreFeedStatus.failure:
        _errorTracker.trackFeedLoadError(
          feedType: widget.feedType,
          errorType: 'load_failed',
          errorMessage: 'Feed failed to load',
          loadTimeMs: _elapsedMs(),
        );
        _trackSlowOperationIfNeeded();
    }
  }

  void _trackSlowOperationIfNeeded() {
    final elapsed = _elapsedMs();
    if (elapsed != null && elapsed > 5000) {
      _errorTracker.trackSlowOperation(
        operation: '${widget.feedType}_feed_load',
        durationMs: elapsed,
        thresholdMs: 5000,
        location: 'explore_${widget.feedType}',
      );
    }
  }

  int? _elapsedMs() {
    if (_loadStartTime == null) return null;
    return DateTime.now().difference(_loadStartTime!).inMilliseconds;
  }
}
