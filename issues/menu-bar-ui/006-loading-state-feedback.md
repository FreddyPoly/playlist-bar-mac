---
id: menu-bar-ui-006
title: Loading/buffering visual feedback across all wait moments
status: done
security: false
owner: agent
depends_on: [playback-controller-001, playback-engine-005]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

Give the dropdown a visible state whenever audio isn't actually flowing but the app is working on
it, instead of looking identical to a normal playing/paused state (or, worse, a frozen app). Per
SPEC.md's "UI (menu bar dropdown)" section, this covers three distinct wait moments:

1. **Playlist switch** — a cache scan is in progress. `PlaybackController` already exposes
   `isLoading` (from `PlaylistLoader`) but nothing in `ContentView.swift` currently reads it.
2. **Fresh stream resolution** — a track is starting for the first time (not resuming an
   already-loaded item) and its stream URL hasn't resolved yet.
3. **Mid-stream stall recovery** — depends on `playback-engine-005` exposing a stalled/buffering
   signal; this issue is the UI consumer of that signal, not the detection logic itself.

## Acceptance criteria

- Each of the three moments above shows a visibly distinct "loading"/"buffering" state — doesn't
  have to be the same visual treatment for all three, but none of them should look like ordinary
  steady-state playing or paused.
- Near-instant operations (a cache-hit playlist switch, a stream that resolves in well under a
  second) shouldn't visibly flicker a loading state in and out — use a short threshold/debounce
  rather than showing it unconditionally on every operation regardless of duration.
- No change to actual playback timing/behavior — this is feedback only, doesn't alter when
  playback actually starts or how long anything takes.

## Notes

Added 2026-08-09, split out from `playback-engine-005` (which originally listed "some way to
distinguish playing from stalled/buffering in the UI" as one of its own acceptance criteria) once
real usage showed the need is broader than just throttled-stream stalls — playlist switching and
fresh-track resolution have the same "silent wait, looks broken" problem. `playback-engine-005`
now owns detecting a stall and the throttling-mitigation investigation; this issue owns turning
that (and the other two wait moments) into something visible in `ContentView.swift`.

## Fix (2026-08-09)

- Added `PlaybackController.isResolvingTrack`, set for the duration of `play(startingAt:
  generation:)`'s call to `TrackAvailabilityResolver.resolveNextPlayable` — covers moment 2
  (fresh stream resolution), reset via the same `switchGeneration` guard pattern already used for
  every other state mutation in that function (so a superseded call can't incorrectly clear a
  newer call's in-flight flag).
- `ContentView` derives `isWaiting = controller.isLoading || controller.isResolvingTrack ||
  controller.isBuffering` — the three moments in one signal — and debounces it via a
  `.task(id: isWaiting)` modifier: flipping to `true` only takes visible effect after it's held
  continuously for 300ms (a fast cache-hit switch or quick resolve never gets there before the
  task is cancelled and restarted), while flipping back to `false` happens immediately.
- Visual treatment: the Play/Pause button's icon becomes a small `ProgressView()` spinner while
  `showLoadingIndicator` is true, replacing (not stacking alongside) the play/pause icon — visibly
  distinct from both steady states, keeping the same minimal SPEC.md aesthetic (no new UI
  elements, just swapping the one icon that was already there).
- No changes to any playback timing/behavior — purely additive state (`isResolvingTrack`) plus a
  view-layer debounce; nothing in `PlaybackController`'s actual resolve/play/skip logic changed.

**Verified live in the packaged app:** clicking Next/Previous and switching playlists both show
the spinner briefly before the pause icon takes over; normal steady playback still shows the
correct play/pause icon with no regression. The third moment (mid-stream stall) reuses the exact
same `isWaiting`/debounce path already exercised above via `isBuffering`, which was independently
verified correct in `playback-engine-005` — not re-triggered live here (no reliable way to force a
real stall on demand), but it's the same code path, not a separate one.
