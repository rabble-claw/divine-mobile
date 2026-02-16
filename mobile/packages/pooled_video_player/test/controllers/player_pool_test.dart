// ABOUTME: Tests for PlayerPool controller
// ABOUTME: Validates singleton pattern, pool operations, and LRU eviction

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pooled_video_player/pooled_video_player.dart';

import '../helpers/test_helpers.dart';

class _MockPooledPlayer extends Mock implements PooledPlayer {}

class _FakeMedia extends Fake implements Media {}

void _setUpFallbacks() {
  registerFallbackValue(_FakeMedia());
  registerFallbackValue(Duration.zero);
  registerFallbackValue(PlaylistMode.single);
}

_MockPooledPlayer _createMockPooledPlayer() {
  final mockPooledPlayer = _MockPooledPlayer();
  final mockPlayer = createMockPlayer();
  final mockController = createMockVideoController();

  when(() => mockPooledPlayer.player).thenReturn(mockPlayer);
  when(() => mockPooledPlayer.videoController).thenReturn(mockController);
  when(() => mockPooledPlayer.isDisposed).thenReturn(false);
  when(mockPooledPlayer.dispose).thenAnswer((_) async {});

  return mockPooledPlayer;
}

void main() {
  setUpAll(_setUpFallbacks);

  group('PlayerPool', () {
    tearDown(() async {
      await PlayerPool.reset();
    });

    group('singleton pattern', () {
      group('init', () {
        test('creates singleton instance', () async {
          await PlayerPool.init();

          expect(PlayerPool.isInitialized, isTrue);
          expect(PlayerPool.instance, isNotNull);
        });

        test('uses default config when not provided', () async {
          await PlayerPool.init();

          expect(PlayerPool.instance.maxPlayers, equals(5));
        });

        test('uses provided config', () async {
          await PlayerPool.init(
            config: const VideoPoolConfig(maxPlayers: 10),
          );

          expect(PlayerPool.instance.maxPlayers, equals(10));
        });

        test('disposes existing instance when re-initializing', () async {
          await PlayerPool.init(
            config: const VideoPoolConfig(maxPlayers: 3),
          );
          final oldInstance = PlayerPool.instance;

          await PlayerPool.init();

          expect(PlayerPool.instance, isNot(same(oldInstance)));
          expect(PlayerPool.instance.maxPlayers, equals(5));
        });
      });

      group('instance', () {
        test('returns singleton after init', () async {
          await PlayerPool.init();

          final instance1 = PlayerPool.instance;
          final instance2 = PlayerPool.instance;

          expect(identical(instance1, instance2), isTrue);
        });

        test('throws StateError when not initialized', () {
          expect(
            () => PlayerPool.instance,
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('PlayerPool not initialized'),
              ),
            ),
          );
        });

        test('returns same instance on multiple calls', () async {
          await PlayerPool.init();

          final instances = <PlayerPool>[];
          for (var i = 0; i < 10; i++) {
            instances.add(PlayerPool.instance);
          }

          expect(
            instances.every((i) => identical(i, instances.first)),
            isTrue,
          );
        });
      });

      group('isInitialized', () {
        test('returns false before init', () {
          expect(PlayerPool.isInitialized, isFalse);
        });

        test('returns true after init', () async {
          await PlayerPool.init();

          expect(PlayerPool.isInitialized, isTrue);
        });

        test('returns false after reset', () async {
          await PlayerPool.init();
          await PlayerPool.reset();

          expect(PlayerPool.isInitialized, isFalse);
        });
      });

      group('reset', () {
        test('disposes singleton', () async {
          await PlayerPool.init();
          expect(PlayerPool.isInitialized, isTrue);

          await PlayerPool.reset();

          expect(PlayerPool.isInitialized, isFalse);
        });

        test('allows re-initialization after reset', () async {
          await PlayerPool.init(
            config: const VideoPoolConfig(maxPlayers: 3),
          );
          await PlayerPool.reset();
          await PlayerPool.init(
            config: const VideoPoolConfig(maxPlayers: 7),
          );

          expect(PlayerPool.instance.maxPlayers, equals(7));
        });

        test('can be called when not initialized', () async {
          await expectLater(PlayerPool.reset(), completes);
        });
      });

      group('instanceForTesting', () {
        test('getter returns current instance', () async {
          await PlayerPool.init();

          expect(PlayerPool.instanceForTesting, equals(PlayerPool.instance));
        });

        test('getter returns null when not initialized', () {
          expect(PlayerPool.instanceForTesting, isNull);
        });

        test('setter replaces instance', () async {
          await PlayerPool.init();
          final customPool = PlayerPool(maxPlayers: 3);

          PlayerPool.instanceForTesting = customPool;

          expect(PlayerPool.instance, equals(customPool));
        });

        test('setter accepts null', () async {
          await PlayerPool.init();

          PlayerPool.instanceForTesting = null;

          expect(PlayerPool.isInitialized, isFalse);
        });
      });
    });

    group('manual instantiation', () {
      test('creates isolated instance', () {
        final pool1 = PlayerPool(maxPlayers: 3);
        final pool2 = PlayerPool();

        expect(identical(pool1, pool2), isFalse);
        expect(pool1.maxPlayers, equals(3));
        expect(pool2.maxPlayers, equals(5));
      });

      test('uses default maxPlayers when not provided', () {
        final pool = PlayerPool();

        expect(pool.maxPlayers, equals(5));
      });

      test('uses provided maxPlayers', () {
        final pool = PlayerPool(maxPlayers: 10);

        expect(pool.maxPlayers, equals(10));
      });

      test('does not affect singleton', () async {
        await PlayerPool.init();
        final manualPool = PlayerPool(maxPlayers: 10);

        expect(PlayerPool.instance.maxPlayers, equals(5));
        expect(manualPool.maxPlayers, equals(10));
        expect(identical(PlayerPool.instance, manualPool), isFalse);
      });
    });

    group('pool operations', () {
      late TestablePlayerPool pool;
      late List<_MockPooledPlayer> createdPlayers;

      setUp(() {
        createdPlayers = [];
        pool = TestablePlayerPool(
          maxPlayers: 3,
          mockPlayerFactory: (url) {
            final player = _createMockPooledPlayer();
            createdPlayers.add(player);
            return player;
          },
        );
      });

      tearDown(() async {
        await pool.dispose();
      });

      group('getPlayer', () {
        test('creates new player for new URL', () async {
          final player = await pool.getPlayer('https://example.com/v1.mp4');

          expect(player, isNotNull);
          expect(createdPlayers.length, equals(1));
        });

        test('returns existing player for same URL', () async {
          final player1 = await pool.getPlayer('https://example.com/v1.mp4');
          final player2 = await pool.getPlayer('https://example.com/v1.mp4');

          expect(identical(player1, player2), isTrue);
          expect(createdPlayers.length, equals(1));
        });

        test('creates players up to maxPlayers', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          expect(pool.playerCount, equals(3));
          expect(createdPlayers.length, equals(3));
        });

        test('recycles LRU player when at capacity', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          await pool.getPlayer('https://example.com/v4.mp4');

          expect(pool.playerCount, equals(3));
          expect(pool.hasPlayer('https://example.com/v1.mp4'), isFalse);
          expect(pool.hasPlayer('https://example.com/v4.mp4'), isTrue);
        });

        test('stops recycled player instead of disposing', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          final recycledPlayer = createdPlayers[0];

          await pool.getPlayer('https://example.com/v4.mp4');

          // Lambda required: mocktail needs chained call inside verify closure.
          // ignore: unnecessary_lambdas
          verify(() => recycledPlayer.player.stop()).called(1);
          verifyNever(recycledPlayer.dispose);
        });

        test('reuses idle player instead of creating new one', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          // v1 gets recycled to idle
          await pool.getPlayer('https://example.com/v4.mp4');

          final countAfterRecycle = createdPlayers.length;

          // v2 gets recycled, idle player (v1) is reused for v5
          await pool.getPlayer('https://example.com/v5.mp4');

          // No new player should have been created
          expect(createdPlayers.length, equals(countAfterRecycle));
        });
      });

      group('hasPlayer', () {
        test('returns false for unknown URL', () {
          expect(pool.hasPlayer('https://example.com/unknown.mp4'), isFalse);
        });

        test('returns true for known URL', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          expect(pool.hasPlayer('https://example.com/v1.mp4'), isTrue);
        });

        test('returns false after player is evicted', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');
          await pool.getPlayer('https://example.com/v4.mp4');

          expect(pool.hasPlayer('https://example.com/v1.mp4'), isFalse);
        });

        test('returns false after player is released', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.release('https://example.com/v1.mp4');

          expect(pool.hasPlayer('https://example.com/v1.mp4'), isFalse);
        });
      });

      group('getExistingPlayer', () {
        test('returns null for unknown URL', () {
          expect(
            pool.getExistingPlayer('https://example.com/unknown.mp4'),
            isNull,
          );
        });

        test('returns player for known URL', () async {
          final created = await pool.getPlayer('https://example.com/v1.mp4');

          final existing = pool.getExistingPlayer(
            'https://example.com/v1.mp4',
          );

          expect(identical(created, existing), isTrue);
        });

        test('marks player as recently used', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          // Touch v1 to make it recently used
          pool.getExistingPlayer('https://example.com/v1.mp4');

          // Should evict v2 (oldest after touch), not v1
          await pool.getPlayer('https://example.com/v4.mp4');

          expect(pool.hasPlayer('https://example.com/v1.mp4'), isTrue);
          expect(pool.hasPlayer('https://example.com/v2.mp4'), isFalse);
        });
      });

      group('release', () {
        test('removes player from pool', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          await pool.release('https://example.com/v1.mp4');

          expect(pool.hasPlayer('https://example.com/v1.mp4'), isFalse);
          expect(pool.playerCount, equals(0));
        });

        test('disposes released player', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          final player = createdPlayers[0];

          await pool.release('https://example.com/v1.mp4');

          verify(player.dispose).called(1);
        });

        test('does nothing for unknown URL', () async {
          await expectLater(
            pool.release('https://example.com/unknown.mp4'),
            completes,
          );
        });
      });

      group('playerCount', () {
        test('returns 0 initially', () {
          expect(pool.playerCount, equals(0));
        });

        test('increments when player added', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          expect(pool.playerCount, equals(1));
        });

        test('stays at max when player evicted', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          expect(pool.playerCount, equals(3));

          await pool.getPlayer('https://example.com/v4.mp4');

          expect(pool.playerCount, equals(3));
        });

        test('decrements when player released', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');

          expect(pool.playerCount, equals(2));

          await pool.release('https://example.com/v1.mp4');

          expect(pool.playerCount, equals(1));
        });

        test('returns 0 after dispose', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');

          await pool.dispose();

          expect(pool.playerCount, equals(0));
        });
      });

      group('LRU recycling', () {
        test('recycles oldest player first', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          await pool.getPlayer('https://example.com/v4.mp4');

          expect(pool.hasPlayer('https://example.com/v1.mp4'), isFalse);
          expect(pool.hasPlayer('https://example.com/v2.mp4'), isTrue);
          expect(pool.hasPlayer('https://example.com/v3.mp4'), isTrue);
          expect(pool.hasPlayer('https://example.com/v4.mp4'), isTrue);
        });

        test('touch moves player to end of LRU', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          // Touch v1 to move it to end
          await pool.getPlayer('https://example.com/v1.mp4');

          // v2 should be recycled now, not v1
          await pool.getPlayer('https://example.com/v4.mp4');

          expect(pool.hasPlayer('https://example.com/v1.mp4'), isTrue);
          expect(pool.hasPlayer('https://example.com/v2.mp4'), isFalse);
        });

        test('correct recycling order with multiple players', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          // Touch in order: v2, v3, v1
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');
          await pool.getPlayer('https://example.com/v1.mp4');

          // Now order should be: v2, v3, v1 (v2 is oldest)
          await pool.getPlayer('https://example.com/v4.mp4');

          expect(pool.hasPlayer('https://example.com/v2.mp4'), isFalse);
          expect(pool.hasPlayer('https://example.com/v3.mp4'), isTrue);
          expect(pool.hasPlayer('https://example.com/v1.mp4'), isTrue);
          expect(pool.hasPlayer('https://example.com/v4.mp4'), isTrue);
        });
      });

      group('stopAll', () {
        test('stops all non-disposed players', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');

          pool.stopAll();

          for (final player in createdPlayers) {
            // ignore: unnecessary_lambdas, chained mock calls need lambda for mocktail
            verify(() => player.player.stop()).called(1);
          }
        });

        test('skips disposed players', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');

          when(() => createdPlayers[0].isDisposed).thenReturn(true);

          pool.stopAll();

          verifyNever(() => createdPlayers[0].player.stop());
          verify(() => createdPlayers[1].player.stop()).called(1);
        });

        test('handles empty pool', () {
          expect(() => pool.stopAll(), returnsNormally);
        });

        test('handles exception during stop gracefully', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          when(() => createdPlayers[0].player.stop()).thenThrow(
            Exception('stop failed'),
          );

          expect(() => pool.stopAll(), returnsNormally);
        });
      });

      group('dispose', () {
        test('disposes all active players', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');

          await pool.dispose();

          for (final player in createdPlayers) {
            verify(player.dispose).called(1);
          }
        });

        test('disposes idle players too', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');

          // Recycle v1 to idle
          await pool.recycle('https://example.com/v1.mp4');
          expect(pool.idleCount, equals(1));

          await pool.dispose();

          // Both active (v2) and idle (v1) should be disposed
          for (final player in createdPlayers) {
            verify(player.dispose).called(1);
          }
          expect(pool.idleCount, equals(0));
        });

        test('clears player count', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');

          await pool.dispose();

          expect(pool.playerCount, equals(0));
        });

        test('can be called multiple times', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          await pool.dispose();
          await pool.dispose();
          await pool.dispose();

          verify(() => createdPlayers[0].dispose()).called(1);
        });

        test('skips already disposed players', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');

          when(() => createdPlayers[0].isDisposed).thenReturn(true);

          await pool.dispose();

          verifyNever(() => createdPlayers[0].dispose());
          verify(() => createdPlayers[1].dispose()).called(1);
        });
      });

      group('recycle', () {
        test('removes player from active pool', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          await pool.recycle('https://example.com/v1.mp4');

          expect(pool.hasPlayer('https://example.com/v1.mp4'), isFalse);
          expect(pool.playerCount, equals(0));
        });

        test('stops player media', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          final player = createdPlayers[0];

          await pool.recycle('https://example.com/v1.mp4');

          // Lambda required: mocktail needs chained call inside verify closure.
          // ignore: unnecessary_lambdas
          verify(() => player.player.stop()).called(1);
        });

        test('adds player to idle list', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          await pool.recycle('https://example.com/v1.mp4');

          expect(pool.idleCount, equals(1));
        });

        test('does not dispose player', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          final player = createdPlayers[0];

          await pool.recycle('https://example.com/v1.mp4');

          verifyNever(player.dispose);
        });

        test('does nothing for unknown URL', () async {
          await expectLater(
            pool.recycle('https://example.com/unknown.mp4'),
            completes,
          );
          expect(pool.idleCount, equals(0));
        });

        test('skips already disposed player', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          when(() => createdPlayers[0].isDisposed).thenReturn(true);

          await pool.recycle('https://example.com/v1.mp4');

          verifyNever(() => createdPlayers[0].player.stop());
          expect(pool.idleCount, equals(0));
        });
      });

      group('idleCount', () {
        test('returns 0 initially', () {
          expect(pool.idleCount, equals(0));
        });

        test('increments when player is recycled', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          await pool.recycle('https://example.com/v1.mp4');

          expect(pool.idleCount, equals(1));
        });

        test('decrements when idle player is reused', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.getPlayer('https://example.com/v2.mp4');
          await pool.getPlayer('https://example.com/v3.mp4');

          // Recycle v1 to idle
          await pool.recycle('https://example.com/v1.mp4');
          expect(pool.idleCount, equals(1));

          // Getting a new URL should reuse idle player
          await pool.getPlayer('https://example.com/v4.mp4');

          expect(pool.idleCount, equals(0));
        });

        test('returns 0 after dispose', () async {
          await pool.getPlayer('https://example.com/v1.mp4');
          await pool.recycle('https://example.com/v1.mp4');

          await pool.dispose();

          expect(pool.idleCount, equals(0));
        });
      });

      group('release with disposed player', () {
        test('skips disposing already disposed player', () async {
          await pool.getPlayer('https://example.com/v1.mp4');

          when(() => createdPlayers[0].isDisposed).thenReturn(true);

          await pool.release('https://example.com/v1.mp4');

          verifyNever(() => createdPlayers[0].dispose());
          expect(pool.hasPlayer('https://example.com/v1.mp4'), isFalse);
        });
      });

      group('recycling with disposed player', () {
        test(
          'skips adding disposed player to idle during LRU recycling',
          () async {
            await pool.getPlayer('https://example.com/v1.mp4');
            await pool.getPlayer('https://example.com/v2.mp4');
            await pool.getPlayer('https://example.com/v3.mp4');

            when(() => createdPlayers[0].isDisposed).thenReturn(true);

            await pool.getPlayer('https://example.com/v4.mp4');

            // v1 removed from active but NOT added to idle
            expect(pool.hasPlayer('https://example.com/v1.mp4'), isFalse);
            expect(pool.idleCount, equals(0));
            verifyNever(() => createdPlayers[0].player.stop());
          },
        );
      });
    });
  });
}
