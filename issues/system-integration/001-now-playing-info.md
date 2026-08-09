---
id: system-integration-001
title: Now Playing info
status: done
security: false
owner: agent
depends_on: [playback-engine-002, playback-controller-001]
spec_ref: "SPEC.md#native-macos-integration"
---

## Description

Publish the current track title and playlist name to `MPNowPlayingInfoCenter` so they appear in
macOS Control Center's Now Playing widget and the lock screen, updating as the track or playback
state changes.

## Acceptance criteria

- While a track plays, Control Center's Now Playing widget shows its title and the active
  playlist name.
- The widget reflects play/pause state and updates promptly when the track changes.

## Notes

Publishes already-displayed local data (track title, playlist name) to a standard system API —
no new external input introduced by this issue.

Implemented as a private `updateNowPlayingInfo()` on `PlaybackController`, triggered reactively
via `didSet` on `currentPlaylist`/`currentIndex`/`isPlaying` rather than called explicitly at each
of the several places those change (switchTo, play, togglePlayPause, advanceOnFinish, step,
reset, selectTrack) — a `didSet` can't be forgotten at a new call site the way an imperative
"don't forget to also call updateNowPlayingInfo() here" convention could. Sets
`MPMediaItemPropertyTitle`, `MPMediaItemPropertyAlbumTitle` (playlist name), and
`MPNowPlayingInfoPropertyPlaybackRate`, plus `MPNowPlayingInfoCenter.default().playbackState`;
clears everything (`nowPlayingInfo = nil`, `playbackState = .stopped`) when nothing is loaded.

Verified within-process: before anything plays, `nowPlayingInfo` is `nil`. After switching to
Jazz, title/album/playback-rate/state all matched the controller's actual state exactly
(`playbackRate: 1.0`, `playbackState: .playing`). Pausing correctly flipped both to `0.0`/
`.paused`. Advancing to the next track correctly updated the title to match.

**Verification limitation:** this confirms the app is calling the API correctly with the right
values (readable back from `MPNowPlayingInfoCenter.default()` within the same process), but I
couldn't independently confirm the *system-wide* Control Center widget actually displays it — no
`nowplaying-cli`-equivalent tool was available, and using the private `MediaRemote` framework to
inspect this from outside the app felt like more surface area than warranted just for
verification. Please glance at Control Center yourself while a track is playing to confirm.
