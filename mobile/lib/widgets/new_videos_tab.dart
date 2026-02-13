// ABOUTME: New Videos tab widget showing recent videos sorted by time
// ABOUTME: Uses NewVideosFeedBloc for state management with BlocProvider

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
import 'package:openvine/widgets/branded_loading_indicator.dart';
import 'package:openvine/widgets/composable_video_grid.dart';
import 'package:openvine/widgets/explore_feed_analytics_listener.dart';
import 'package:rxdart/rxdart.dart';

/// Tab widget displaying new/recent videos sorted by time.
///
/// Owns its [NewVideosFeedBloc] via [BlocProvider] and uses
/// [AutomaticKeepAliveClientMixin] to preserve scroll position and
/// cached videos across tab switches.
class NewVideosTab extends ConsumerStatefulWidget {
  const NewVideosTab({super.key});

  @override
  ConsumerState<NewVideosTab> createState() => _NewVideosTabState();
}

class _NewVideosTabState extends ConsumerState<NewVideosTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final videosRepository = ref.read(videosRepositoryProvider);

    return BlocProvider(
      create: (_) => NewVideosFeedBloc(
        fetch: () => videosRepository.getNewVideos(limit: 20),
        fetchMore: (current) => videosRepository.getNewVideos(
          limit: 20,
          until: current.last.createdAt - 1,
        ),
        pageSize: 20,
      )..add(const ExploreFeedStarted()),
      child: const _NewVideosTabView(),
    );
  }
}

class _NewVideosTabView extends StatelessWidget {
  const _NewVideosTabView();

  @override
  Widget build(BuildContext context) {
    return ExploreFeedAnalyticsListener<NewVideosFeedBloc>(
      feedType: 'new_vines',
      child: BlocBuilder<NewVideosFeedBloc, ExploreFeedState>(
        builder: (context, state) {
          return switch (state.status) {
            ExploreFeedStatus.initial ||
            ExploreFeedStatus.loading => const _NewVideosLoadingState(),
            ExploreFeedStatus.failure => const _NewVideosErrorState(),
            ExploreFeedStatus.success => _NewVideosContent(
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

/// Content widget displaying the video grid.
class _NewVideosContent extends StatefulWidget {
  const _NewVideosContent({
    required this.videos,
    this.isLoadingMore = false,
    this.hasMoreContent = false,
  });

  final List<VideoEvent> videos;
  final bool isLoadingMore;
  final bool hasMoreContent;

  @override
  State<_NewVideosContent> createState() => _NewVideosContentState();
}

class _NewVideosContentState extends State<_NewVideosContent> {
  late final StreamController<List<VideoEvent>> _videosStreamController;

  @override
  void initState() {
    super.initState();
    _videosStreamController = StreamController<List<VideoEvent>>.broadcast();
  }

  @override
  void didUpdateWidget(_NewVideosContent oldWidget) {
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
    final bloc = context.read<NewVideosFeedBloc>();

    return ComposableVideoGrid(
      videos: widget.videos,
      useMasonryLayout: true,
      onVideoTap: (videoList, index) {
        context.push(
          PooledFullscreenVideoFeedScreen.path,
          extra: PooledFullscreenVideoFeedArgs(
            videosStream: _videosStreamController.stream.startWith(videoList),
            initialIndex: index,
            onLoadMore: () => bloc.add(const ExploreFeedLoadMoreRequested()),
            contextTitle: 'New Videos',
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
      emptyBuilder: _NewVideosEmptyState.new,
    );
  }
}

/// Empty state widget for NewVideosTab.
class _NewVideosEmptyState extends StatelessWidget {
  const _NewVideosEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.video_library, size: 64, color: VineTheme.secondaryText),
          const SizedBox(height: 16),
          Text(
            'No videos in New Videos',
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

/// Error state widget for NewVideosTab.
class _NewVideosErrorState extends StatelessWidget {
  const _NewVideosErrorState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error, size: 64, color: VineTheme.likeRed),
          const SizedBox(height: 16),
          Text(
            'Failed to load videos',
            style: TextStyle(color: VineTheme.likeRed, fontSize: 18),
          ),
        ],
      ),
    );
  }
}

/// Loading state widget for NewVideosTab.
class _NewVideosLoadingState extends StatelessWidget {
  const _NewVideosLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: BrandedLoadingIndicator(size: 80));
  }
}
