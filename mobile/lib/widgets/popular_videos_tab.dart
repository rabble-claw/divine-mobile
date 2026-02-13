// ABOUTME: Popular Videos tab widget showing trending videos sorted by loops
// ABOUTME: Uses PopularVideosFeedBloc for state management with BlocProvider

import 'dart:async';

import 'package:divine_ui/divine_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:models/models.dart';
import 'package:openvine/blocs/explore_feed/explore_feed_bloc.dart';
import 'package:openvine/providers/app_providers.dart';
import 'package:openvine/screens/feed/pooled_fullscreen_video_feed_screen.dart';
import 'package:openvine/services/top_hashtags_service.dart';
import 'package:openvine/widgets/branded_loading_indicator.dart';
import 'package:openvine/widgets/composable_video_grid.dart';
import 'package:openvine/widgets/explore_feed_analytics_listener.dart';
import 'package:openvine/widgets/scroll_to_hide_mixin.dart';
import 'package:openvine/widgets/trending_hashtags_section.dart';
import 'package:rxdart/rxdart.dart';

/// Tab widget displaying popular/trending videos sorted by loop count.
///
/// Owns its [PopularVideosFeedBloc] via [BlocProvider] and uses
/// [AutomaticKeepAliveClientMixin] to preserve scroll position and
/// cached videos across tab switches.
class PopularVideosTab extends ConsumerStatefulWidget {
  const PopularVideosTab({super.key});

  @override
  ConsumerState<PopularVideosTab> createState() => _PopularVideosTabState();
}

class _PopularVideosTabState extends ConsumerState<PopularVideosTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final videosRepository = ref.read(videosRepositoryProvider);

    return BlocProvider(
      create: (_) => PopularVideosFeedBloc(
        fetch: () => videosRepository.getPopularVideos(limit: 20),
        fetchMore: (current) => videosRepository.getPopularVideos(
          limit: 20,
          until: current.last.createdAt - 1,
        ),
        pageSize: 20,
      )..add(const ExploreFeedStarted()),
      child: const _PopularVideosTabView(),
    );
  }
}

class _PopularVideosTabView extends StatelessWidget {
  const _PopularVideosTabView();

  @override
  Widget build(BuildContext context) {
    return ExploreFeedAnalyticsListener<PopularVideosFeedBloc>(
      feedType: 'popular',
      child: BlocBuilder<PopularVideosFeedBloc, ExploreFeedState>(
        builder: (context, state) {
          return switch (state.status) {
            ExploreFeedStatus.initial ||
            ExploreFeedStatus.loading => const _PopularVideosLoadingState(),
            ExploreFeedStatus.failure => const _PopularVideosErrorState(),
            ExploreFeedStatus.success => _PopularVideosTrendingContent(
              videos: state.videos,
              isLoadingMore: state.isLoadingMore,
              hasMoreContent: state.hasMore,
            ),
          };
        },
      ),
    );
  }
}

/// Content widget displaying trending hashtags and video grid.
///
/// Hashtags push up as user scrolls down (1:1 with scroll distance).
/// When scrolling up, hashtags slide back in as an overlay with animation.
class _PopularVideosTrendingContent extends StatefulWidget {
  const _PopularVideosTrendingContent({
    required this.videos,
    required this.isLoadingMore,
    required this.hasMoreContent,
  });

  final List<VideoEvent> videos;
  final bool isLoadingMore;
  final bool hasMoreContent;

  @override
  State<_PopularVideosTrendingContent> createState() =>
      _PopularVideosTrendingContentState();
}

class _PopularVideosTrendingContentState
    extends State<_PopularVideosTrendingContent>
    with ScrollToHideMixin {
  late final StreamController<List<VideoEvent>> _videosStreamController;

  @override
  void initState() {
    super.initState();
    _videosStreamController = StreamController<List<VideoEvent>>.broadcast();
  }

  @override
  void didUpdateWidget(_PopularVideosTrendingContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.videos != oldWidget.videos) {
      _videosStreamController.add(widget.videos);
    }
  }

  @override
  void dispose() {
    _videosStreamController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PopularVideosFeedBloc>();
    final hashtags = TopHashtagsService.instance.getTopHashtags(limit: 20);

    measureHeaderHeight();

    return Stack(
      children: [
        // Grid takes full space
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: handleScrollNotification,
            child: ComposableVideoGrid(
              videos: widget.videos,
              useMasonryLayout: true,
              padding: EdgeInsets.only(
                left: 4,
                right: 4,
                bottom: 4,
                top: headerHeight > 0 ? headerHeight + 4 : 4,
              ),
              onVideoTap: (videoList, index) {
                context.push(
                  PooledFullscreenVideoFeedScreen.path,
                  extra: PooledFullscreenVideoFeedArgs(
                    videosStream: _videosStreamController.stream.startWith(
                      videoList,
                    ),
                    initialIndex: index,
                    onLoadMore: () =>
                        bloc.add(const ExploreFeedLoadMoreRequested()),
                    contextTitle: 'Popular Videos',
                  ),
                );
              },
              onRefresh: () async {
                bloc.add(const ExploreFeedRefreshRequested());
              },
              onLoadMore: () async {
                bloc.add(const ExploreFeedLoadMoreRequested());
              },
              isLoadingMore: widget.isLoadingMore,
              hasMoreContent: widget.hasMoreContent,
              emptyBuilder: () => const _PopularVideosEmptyState(),
            ),
          ),
        ),
        // Hashtags overlay on top, animated when returning
        AnimatedPositioned(
          duration: headerFullyHidden
              ? const Duration(milliseconds: 250)
              : Duration.zero,
          curve: Curves.easeOut,
          top: headerOffset,
          left: 0,
          right: 0,
          child: TrendingHashtagsSection(
            key: headerKey,
            hashtags: hashtags,
            isLoading: !TopHashtagsService.instance.isLoaded,
          ),
        ),
      ],
    );
  }
}

/// Empty state widget for PopularVideosTab.
class _PopularVideosEmptyState extends StatelessWidget {
  const _PopularVideosEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.video_library, size: 64, color: VineTheme.secondaryText),
          const SizedBox(height: 16),
          Text(
            'No videos in Popular Videos',
            style: TextStyle(
              color: VineTheme.primaryText,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Check back later for new content',
            style: TextStyle(color: VineTheme.secondaryText, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// Error state widget for PopularVideosTab.
class _PopularVideosErrorState extends StatelessWidget {
  const _PopularVideosErrorState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error, size: 64, color: VineTheme.likeRed),
          const SizedBox(height: 16),
          Text(
            'Failed to load trending videos',
            style: TextStyle(color: VineTheme.likeRed, fontSize: 18),
          ),
        ],
      ),
    );
  }
}

/// Loading state widget for PopularVideosTab.
class _PopularVideosLoadingState extends StatelessWidget {
  const _PopularVideosLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: BrandedLoadingIndicator(size: 80));
  }
}
