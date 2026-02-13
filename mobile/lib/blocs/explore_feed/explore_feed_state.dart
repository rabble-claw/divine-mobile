// ABOUTME: State for ExploreFeedBloc — shared across all explore tabs.
// ABOUTME: Tracks videos, loading/pagination status, and hasMore flag.

part of 'explore_feed_bloc.dart';

/// Status of an explore feed tab.
enum ExploreFeedStatus {
  /// No data loaded yet.
  initial,

  /// Currently loading videos.
  loading,

  /// Videos loaded successfully.
  success,

  /// An error occurred while loading videos.
  failure,
}

/// State for the ExploreFeedBloc.
final class ExploreFeedState extends Equatable {
  const ExploreFeedState({
    this.status = ExploreFeedStatus.initial,
    this.videos = const [],
    this.hasMore = true,
    this.isLoadingMore = false,
  });

  /// The current loading status.
  final ExploreFeedStatus status;

  /// The list of videos for this tab.
  final List<VideoEvent> videos;

  /// Whether more videos can be loaded via pagination.
  final bool hasMore;

  /// Whether a load-more operation is in progress.
  final bool isLoadingMore;

  /// Create a copy with updated values.
  ExploreFeedState copyWith({
    ExploreFeedStatus? status,
    List<VideoEvent>? videos,
    bool? hasMore,
    bool? isLoadingMore,
  }) {
    return ExploreFeedState(
      status: status ?? this.status,
      videos: videos ?? this.videos,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }

  @override
  List<Object?> get props => [status, videos, hasMore, isLoadingMore];
}
