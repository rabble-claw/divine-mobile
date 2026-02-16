# Player Recycling: Stop Destroying Players on Scroll

## Problem

When the user scrolls through videos, the controller destroys and recreates native video players for every single page change. This is expensive — each cycle involves disposing a native media decoder and allocating a new one.

**Current flow (wasteful):**
```
Scroll forward → _releasePlayer(oldIndex) → pool.release(url) → native player DISPOSED
Load new video → pool.getPlayer(url) → brand new native player CREATED
Scroll back   → pool.getPlayer(url) → brand new native player CREATED (again!)
```

The pool has an LRU cache, but the controller bypasses it by always calling `pool.release()`, which removes the player from the pool entirely.

## Proposed Change

Stop calling `pool.release()` when a player leaves the preload window. Instead, just pause it and remove it from the controller's internal tracking. Let the pool's LRU eviction handle cleanup when it actually needs room.

**New flow (recycled):**
```
Scroll forward → _releasePlayer(oldIndex) → player PAUSED, stays in pool LRU cache
Load new video → pool.getPlayer(url) → returns CACHED player (instant, no native allocation)
Pool is full   → pool.getPlayer(newUrl) → LRU eviction disposes oldest player, creates new one
```

## Changes Required

### 1. `_releasePlayer` — stop calling `pool.release()`

**Before:**
```dart
void _releasePlayer(int index) {
  _stopPositionTimer(index);
  _bufferTimeoutTimers[index]?.cancel();
  _bufferTimeoutTimers.remove(index);
  unawaited(_bufferSubscriptions[index]?.cancel());
  _bufferSubscriptions.remove(index);
  _loadedPlayers.remove(index);
  _loadStates.remove(index);
  _loadingIndices.remove(index);
  _notifyIndex(index);
}
```

Currently `_releasePlayer` doesn't call `pool.release()` directly — but `dispose()` does via `pool.release(_videos[i].url)`. The key change is in `dispose()` and ensuring the player is paused/stopped when removed from the preload window.

**After:**
```dart
void _releasePlayer(int index) {
  _stopPositionTimer(index);
  _bufferTimeoutTimers[index]?.cancel();
  _bufferTimeoutTimers.remove(index);
  unawaited(_bufferSubscriptions[index]?.cancel());
  _bufferSubscriptions.remove(index);

  // Pause and stop the player but leave it in the pool's LRU cache
  // for potential reuse if the user scrolls back.
  final pooledPlayer = _loadedPlayers.remove(index);
  if (pooledPlayer != null && !pooledPlayer.isDisposed) {
    unawaited(pooledPlayer.player.pause());
    unawaited(pooledPlayer.player.stop());
  }

  _loadStates.remove(index);
  _loadingIndices.remove(index);
  _notifyIndex(index);
}
```

### 2. `_loadPlayer` — handle cached players from pool

When `pool.getPlayer(url)` returns a cached player (one we previously "released" from the controller but left in the pool), the player may already have the correct media loaded. We need to handle this case — reset state and re-open the media rather than assuming it's a fresh player.

No change needed here actually — `_loadPlayer` already calls `player.stop()` then `player.open()` which resets state regardless of whether the player is new or cached. The existing flow handles both cases.

### 3. `dispose()` — release from pool on controller dispose

When the controller is fully disposed (not just releasing from preload window), we DO want to release players from the pool so they don't leak:

**Before (current):**
```dart
for (var i = 0; i < _videos.length; i++) {
  if (_loadedPlayers.containsKey(i)) {
    unawaited(pool.release(_videos[i].url));
  }
}
```

**After:**
```dart
// Release all players that this controller loaded from the pool.
// This is a full dispose — we don't want to keep them cached.
for (var i = 0; i < _videos.length; i++) {
  if (_loadedPlayers.containsKey(i)) {
    unawaited(pool.release(_videos[i].url));
  }
}
```

No change needed — `dispose()` should still call `pool.release()` since the controller is going away permanently.

### 4. Consider: should `dispose()` release ALL urls this controller ever loaded?

Currently `dispose()` only releases players still in `_loadedPlayers` at dispose time. But with the recycling change, previously-scrolled-past videos are no longer in `_loadedPlayers` — they're only in the pool's LRU cache. These will eventually be evicted by the pool naturally, which is fine. No change needed.

## Impact

### Performance Gains
- **Scroll back**: instant playback (no native player creation, media already loaded)
- **Scroll forward**: if pool has room, no eviction needed. If pool is full, only the oldest unused player is destroyed (instead of destroying on every scroll).
- **Memory**: same peak memory — pool's `maxPlayers` still limits total native players

### What Stays the Same
- Pool's `maxPlayers` limit (default 5) still enforced
- `_isPlayerDisposed` checks still catch evicted players
- `dispose()` still releases from pool on controller teardown
- `setActive(active: false)` behavior — currently calls `_releaseAllPlayers()` which calls `_releasePlayer()` for each index. With this change, those players stay in the pool (paused) instead of being disposed. This is actually better — reactivating the feed can reuse them instantly.

### Risk
- Slightly higher steady-state memory if the user only scrolls forward (pool keeps 5 paused players instead of the 4 in the preload window). Marginal — one extra native player at most.

## Test Changes

Update tests that verify `pool.release()` is called during preload window shifts. Those should now verify the player is paused/stopped instead. The test for `dispose()` calling `pool.release()` stays the same.

## Summary

One method change (`_releasePlayer`), zero architecture changes. The pool's existing LRU eviction does all the heavy lifting — we just need to stop bypassing it.
