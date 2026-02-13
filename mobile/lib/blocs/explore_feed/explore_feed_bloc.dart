// ABOUTME: Generic BLoC for explore feed tabs (New Videos, Popular, etc.)
// ABOUTME: One class, multiple instances — each tab injects its own fetchers.
// ABOUTME: Handles fetch, load more, refresh, and deactivation (trim).

import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/models.dart';

part 'explore_feed_event.dart';
part 'explore_feed_state.dart';

/// Fetches the first page of videos.
typedef VideoFetcher = Future<List<VideoEvent>> Function();

/// Fetches the next page given the current list.
/// The implementation decides how to paginate (cursor, offset, etc).
typedef VideoPageFetcher =
    Future<List<VideoEvent>> Function(List<VideoEvent> currentVideos);

/// Generic BLoC for explore feed tabs.
///
/// Each explore tab (New Videos, Popular, Classic Vines, For You) creates
/// an instance with its own [fetch] and [fetchMore] callbacks. The BLoC
/// handles state management; pagination strategy lives in the callbacks.
class ExploreFeedBloc extends Bloc<ExploreFeedEvent, ExploreFeedState> {
  ExploreFeedBloc({
    required VideoFetcher fetch,
    required VideoPageFetcher fetchMore,
    int pageSize = 5,
    this.maxCachedVideos = 25,
  }) : _fetch = fetch,
       _fetchMore = fetchMore,
       _pageSize = pageSize,
       super(const ExploreFeedState()) {
    on<ExploreFeedStarted>(_onStarted);
    on<ExploreFeedLoadMoreRequested>(_onLoadMore, transformer: droppable());
    on<ExploreFeedRefreshRequested>(_onRefresh);
    on<ExploreFeedDeactivated>(_onDeactivated);
  }

  final VideoFetcher _fetch;
  final VideoPageFetcher _fetchMore;
  final int _pageSize;

  /// Maximum number of videos to keep when the tab goes off-screen.
  final int maxCachedVideos;

  Future<void> _onStarted(
    ExploreFeedStarted event,
    Emitter<ExploreFeedState> emit,
  ) async {
    emit(state.copyWith(status: ExploreFeedStatus.loading));
    try {
      final videos = await _fetch();
      emit(
        state.copyWith(
          status: ExploreFeedStatus.success,
          videos: videos,
          hasMore: videos.length >= _pageSize,
        ),
      );
    } catch (e, s) {
      addError(e, s);
      emit(state.copyWith(status: ExploreFeedStatus.failure));
    }
  }

  Future<void> _onLoadMore(
    ExploreFeedLoadMoreRequested event,
    Emitter<ExploreFeedState> emit,
  ) async {
    if (!state.hasMore || state.isLoadingMore || state.videos.isEmpty) return;
    emit(state.copyWith(isLoadingMore: true));
    try {
      final moreVideos = await _fetchMore(state.videos);
      emit(
        state.copyWith(
          videos: [...state.videos, ...moreVideos],
          hasMore: moreVideos.length >= _pageSize,
          isLoadingMore: false,
        ),
      );
    } catch (e, s) {
      addError(e, s);
      emit(state.copyWith(isLoadingMore: false));
    }
  }

  Future<void> _onRefresh(
    ExploreFeedRefreshRequested event,
    Emitter<ExploreFeedState> emit,
  ) async {
    emit(const ExploreFeedState(status: ExploreFeedStatus.loading));
    try {
      final videos = await _fetch();
      emit(
        state.copyWith(
          status: ExploreFeedStatus.success,
          videos: videos,
          hasMore: videos.length >= _pageSize,
        ),
      );
    } catch (e, s) {
      addError(e, s);
      emit(state.copyWith(status: ExploreFeedStatus.failure));
    }
  }

  /// Trims the video list to [maxCachedVideos], keeping the most recent
  /// (tail) of the list. Called when the tab goes off-screen.
  void _onDeactivated(
    ExploreFeedDeactivated event,
    Emitter<ExploreFeedState> emit,
  ) {
    if (state.videos.length <= maxCachedVideos) return;
    emit(
      state.copyWith(
        videos: state.videos.sublist(state.videos.length - maxCachedVideos),
      ),
    );
  }
}

/// Thin subclass for the New Videos tab.
class NewVideosFeedBloc extends ExploreFeedBloc {
  NewVideosFeedBloc({
    required super.fetch,
    required super.fetchMore,
    super.pageSize,
    super.maxCachedVideos,
  });
}

/// Thin subclass for the Popular Videos tab.
class PopularVideosFeedBloc extends ExploreFeedBloc {
  PopularVideosFeedBloc({
    required super.fetch,
    required super.fetchMore,
    super.pageSize,
    super.maxCachedVideos,
  });
}

/// Thin subclass for the Classic Vines tab.
class ClassicVinesFeedBloc extends ExploreFeedBloc {
  ClassicVinesFeedBloc({
    required super.fetch,
    required super.fetchMore,
    super.pageSize = 100,
    super.maxCachedVideos,
  });
}

/// Thin subclass for the For You tab.
class ForYouFeedBloc extends ExploreFeedBloc {
  ForYouFeedBloc({
    required super.fetch,
    required super.fetchMore,
    super.pageSize,
    super.maxCachedVideos,
  });
}
