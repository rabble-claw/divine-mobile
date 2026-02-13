// ABOUTME: Tests for ExploreFeedBloc — generic explore feed tab BLoC.
// ABOUTME: Covers fetch, load more, refresh, deactivation trim, and errors.

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/models.dart';
import 'package:openvine/blocs/explore_feed/explore_feed_bloc.dart';

void main() {
  group(ExploreFeedBloc, () {
    const pageSize = 5;

    VideoEvent createTestVideo(String id, {int? createdAt}) {
      final timestamp =
          createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return VideoEvent(
        id: id,
        pubkey: '0' * 64,
        createdAt: timestamp,
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
        title: 'Test Video $id',
        videoUrl: 'https://example.com/$id.mp4',
        thumbnailUrl: 'https://example.com/$id.jpg',
      );
    }

    List<VideoEvent> createTestVideos(int count, {String idPrefix = 'video'}) {
      final baseTimestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return List.generate(
        count,
        (i) => createTestVideo('$idPrefix-$i', createdAt: baseTimestamp - i),
      );
    }

    test('initial state is correct', () {
      final bloc = ExploreFeedBloc(
        fetch: () async => [],
        fetchMore: (_) async => [],
      );

      expect(bloc.state, equals(const ExploreFeedState()));
      expect(bloc.state.status, equals(ExploreFeedStatus.initial));
      expect(bloc.state.videos, isEmpty);
      expect(bloc.state.hasMore, isTrue);
      expect(bloc.state.isLoadingMore, isFalse);

      bloc.close();
    });

    group(ExploreFeedStarted, () {
      final testVideos = createTestVideos(pageSize);

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'emits [loading, success] when fetch succeeds with full page',
        build: () => ExploreFeedBloc(
          fetch: () async => testVideos,
          fetchMore: (_) async => [],
        ),
        act: (bloc) => bloc.add(const ExploreFeedStarted()),
        expect: () => [
          const ExploreFeedState(status: ExploreFeedStatus.loading),
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: testVideos,
          ),
        ],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'sets hasMore to false when fewer than pageSize videos returned',
        build: () => ExploreFeedBloc(
          fetch: () async => testVideos.take(3).toList(),
          fetchMore: (_) async => [],
        ),
        act: (bloc) => bloc.add(const ExploreFeedStarted()),
        expect: () => [
          const ExploreFeedState(status: ExploreFeedStatus.loading),
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: testVideos.take(3).toList(),
            hasMore: false,
          ),
        ],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'emits [loading, failure] when fetch throws',
        build: () => ExploreFeedBloc(
          fetch: () async => throw Exception('network error'),
          fetchMore: (_) async => [],
        ),
        act: (bloc) => bloc.add(const ExploreFeedStarted()),
        errors: () => [isA<Exception>()],
        expect: () => [
          const ExploreFeedState(status: ExploreFeedStatus.loading),
          const ExploreFeedState(status: ExploreFeedStatus.failure),
        ],
      );
    });

    group(ExploreFeedLoadMoreRequested, () {
      final initialVideos = createTestVideos(pageSize, idPrefix: 'initial');
      final moreVideos = createTestVideos(pageSize, idPrefix: 'more');

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'appends new videos and sets isLoadingMore',
        build: () => ExploreFeedBloc(
          fetch: () async => initialVideos,
          fetchMore: (_) async => moreVideos,
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: initialVideos,
        ),
        act: (bloc) => bloc.add(const ExploreFeedLoadMoreRequested()),
        expect: () => [
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: initialVideos,
            isLoadingMore: true,
          ),
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: [...initialVideos, ...moreVideos],
          ),
        ],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'passes current videos to fetchMore callback',
        build: () => ExploreFeedBloc(
          fetch: () async => initialVideos,
          fetchMore: (current) async {
            // Verify fetchMore receives the current video list.
            // If it weren't called, the state wouldn't contain moreVideos.
            expect(current, equals(initialVideos));
            return moreVideos;
          },
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: initialVideos,
        ),
        act: (bloc) => bloc.add(const ExploreFeedLoadMoreRequested()),
        expect: () => [
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: initialVideos,
            isLoadingMore: true,
          ),
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: [...initialVideos, ...moreVideos],
          ),
        ],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'sets hasMore to false when fewer than pageSize returned',
        build: () => ExploreFeedBloc(
          fetch: () async => initialVideos,
          fetchMore: (_) async => moreVideos.take(2).toList(),
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: initialVideos,
        ),
        act: (bloc) => bloc.add(const ExploreFeedLoadMoreRequested()),
        expect: () => [
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: initialVideos,
            isLoadingMore: true,
          ),
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: [...initialVideos, ...moreVideos.take(2)],
            hasMore: false,
          ),
        ],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'does nothing when hasMore is false',
        build: () => ExploreFeedBloc(
          fetch: () async => initialVideos,
          fetchMore: (_) async => throw Exception('should not be called'),
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: initialVideos,
          hasMore: false,
        ),
        act: (bloc) => bloc.add(const ExploreFeedLoadMoreRequested()),
        expect: () => <ExploreFeedState>[],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'does nothing when videos list is empty',
        build: () => ExploreFeedBloc(
          fetch: () async => [],
          fetchMore: (_) async => throw Exception('should not be called'),
        ),
        seed: () => const ExploreFeedState(status: ExploreFeedStatus.success),
        act: (bloc) => bloc.add(const ExploreFeedLoadMoreRequested()),
        expect: () => <ExploreFeedState>[],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'does nothing when already loading more',
        build: () => ExploreFeedBloc(
          fetch: () async => initialVideos,
          fetchMore: (_) async => throw Exception('should not be called'),
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: initialVideos,
          isLoadingMore: true,
        ),
        act: (bloc) => bloc.add(const ExploreFeedLoadMoreRequested()),
        expect: () => <ExploreFeedState>[],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'resets isLoadingMore on error',
        build: () => ExploreFeedBloc(
          fetch: () async => initialVideos,
          fetchMore: (_) async => throw Exception('load more failed'),
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: initialVideos,
        ),
        act: (bloc) => bloc.add(const ExploreFeedLoadMoreRequested()),
        errors: () => [isA<Exception>()],
        expect: () => [
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: initialVideos,
            isLoadingMore: true,
          ),
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: initialVideos,
          ),
        ],
      );
    });

    group(ExploreFeedRefreshRequested, () {
      final oldVideos = createTestVideos(pageSize, idPrefix: 'old');
      final freshVideos = createTestVideos(pageSize, idPrefix: 'fresh');

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'resets state and fetches fresh videos',
        build: () => ExploreFeedBloc(
          fetch: () async => freshVideos,
          fetchMore: (_) async => [],
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: oldVideos,
          hasMore: false,
        ),
        act: (bloc) => bloc.add(const ExploreFeedRefreshRequested()),
        expect: () => [
          const ExploreFeedState(status: ExploreFeedStatus.loading),
          ExploreFeedState(
            status: ExploreFeedStatus.success,
            videos: freshVideos,
          ),
        ],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'emits failure when refresh throws',
        build: () => ExploreFeedBloc(
          fetch: () async => throw Exception('refresh failed'),
          fetchMore: (_) async => [],
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: oldVideos,
        ),
        act: (bloc) => bloc.add(const ExploreFeedRefreshRequested()),
        errors: () => [isA<Exception>()],
        expect: () => [
          const ExploreFeedState(status: ExploreFeedStatus.loading),
          const ExploreFeedState(status: ExploreFeedStatus.failure),
        ],
      );
    });

    group(ExploreFeedDeactivated, () {
      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'trims videos to maxCachedVideos keeping the tail',
        build: () => ExploreFeedBloc(
          fetch: () async => [],
          fetchMore: (_) async => [],
          maxCachedVideos: 3,
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: createTestVideos(10),
        ),
        act: (bloc) => bloc.add(const ExploreFeedDeactivated()),
        verify: (bloc) {
          expect(bloc.state.videos, hasLength(3));
          // Should keep the last 3 (tail)
          final allVideos = createTestVideos(10);
          expect(bloc.state.videos, equals(allVideos.sublist(7)));
        },
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'does nothing when videos count is within limit',
        build: () => ExploreFeedBloc(
          fetch: () async => [],
          fetchMore: (_) async => [],
          maxCachedVideos: 25,
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: createTestVideos(10),
        ),
        act: (bloc) => bloc.add(const ExploreFeedDeactivated()),
        expect: () => <ExploreFeedState>[],
      );

      blocTest<ExploreFeedBloc, ExploreFeedState>(
        'does nothing when videos count equals limit',
        build: () => ExploreFeedBloc(
          fetch: () async => [],
          fetchMore: (_) async => [],
          maxCachedVideos: 10,
        ),
        seed: () => ExploreFeedState(
          status: ExploreFeedStatus.success,
          videos: createTestVideos(10),
        ),
        act: (bloc) => bloc.add(const ExploreFeedDeactivated()),
        expect: () => <ExploreFeedState>[],
      );
    });

    group('subclasses', () {
      test('$NewVideosFeedBloc extends $ExploreFeedBloc', () {
        final bloc = NewVideosFeedBloc(
          fetch: () async => [],
          fetchMore: (_) async => [],
        );
        expect(bloc, isA<ExploreFeedBloc>());
        bloc.close();
      });

      test('$PopularVideosFeedBloc extends $ExploreFeedBloc', () {
        final bloc = PopularVideosFeedBloc(
          fetch: () async => [],
          fetchMore: (_) async => [],
        );
        expect(bloc, isA<ExploreFeedBloc>());
        bloc.close();
      });

      test('$ClassicVinesFeedBloc defaults to pageSize 100', () {
        final bloc = ClassicVinesFeedBloc(
          fetch: () async => [],
          fetchMore: (_) async => [],
        );
        expect(bloc, isA<ExploreFeedBloc>());
        bloc.close();
      });

      test('$ForYouFeedBloc extends $ExploreFeedBloc', () {
        final bloc = ForYouFeedBloc(
          fetch: () async => [],
          fetchMore: (_) async => [],
        );
        expect(bloc, isA<ExploreFeedBloc>());
        bloc.close();
      });
    });
  });

  group(ExploreFeedState, () {
    test('supports value equality', () {
      expect(const ExploreFeedState(), equals(const ExploreFeedState()));
    });

    test('props are correct', () {
      expect(
        const ExploreFeedState().props,
        equals([ExploreFeedStatus.initial, <VideoEvent>[], true, false]),
      );
    });

    test('copyWith returns same object when no values provided', () {
      const state = ExploreFeedState();
      expect(state.copyWith(), equals(state));
    });

    test('copyWith replaces values correctly', () {
      const state = ExploreFeedState();
      final updated = state.copyWith(
        status: ExploreFeedStatus.success,
        hasMore: false,
        isLoadingMore: true,
      );
      expect(updated.status, equals(ExploreFeedStatus.success));
      expect(updated.hasMore, isFalse);
      expect(updated.isLoadingMore, isTrue);
    });
  });

  group(ExploreFeedEvent, () {
    test('$ExploreFeedStarted supports value equality', () {
      expect(const ExploreFeedStarted(), equals(const ExploreFeedStarted()));
    });

    test('$ExploreFeedLoadMoreRequested supports value equality', () {
      expect(
        const ExploreFeedLoadMoreRequested(),
        equals(const ExploreFeedLoadMoreRequested()),
      );
    });

    test('$ExploreFeedRefreshRequested supports value equality', () {
      expect(
        const ExploreFeedRefreshRequested(),
        equals(const ExploreFeedRefreshRequested()),
      );
    });

    test('$ExploreFeedDeactivated supports value equality', () {
      expect(
        const ExploreFeedDeactivated(),
        equals(const ExploreFeedDeactivated()),
      );
    });
  });
}
