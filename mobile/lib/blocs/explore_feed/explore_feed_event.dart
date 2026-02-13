// ABOUTME: Events for ExploreFeedBloc — shared across all explore tabs.

part of 'explore_feed_bloc.dart';

/// Base class for all explore feed events.
sealed class ExploreFeedEvent extends Equatable {
  const ExploreFeedEvent();
}

/// Start the feed — fetch the first page of videos.
final class ExploreFeedStarted extends ExploreFeedEvent {
  const ExploreFeedStarted();

  @override
  List<Object?> get props => [];
}

/// Request to load more videos (pagination).
///
/// Dropped if already loading more (uses [droppable] transformer).
final class ExploreFeedLoadMoreRequested extends ExploreFeedEvent {
  const ExploreFeedLoadMoreRequested();

  @override
  List<Object?> get props => [];
}

/// Request to refresh the feed — reset and fetch from scratch.
final class ExploreFeedRefreshRequested extends ExploreFeedEvent {
  const ExploreFeedRefreshRequested();

  @override
  List<Object?> get props => [];
}

/// Sent when the tab goes off-screen.
///
/// Trims the video list to [ExploreFeedBloc.maxCachedVideos] to free
/// memory while preserving scroll position via [AutomaticKeepAliveClientMixin].
final class ExploreFeedDeactivated extends ExploreFeedEvent {
  const ExploreFeedDeactivated();

  @override
  List<Object?> get props => [];
}
