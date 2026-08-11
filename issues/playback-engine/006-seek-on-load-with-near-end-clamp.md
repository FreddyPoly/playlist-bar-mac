---
id: playback-engine-006
title: Seek to a start position on load, with near-end clamp
status: done
security: false
owner: agent
depends_on: [playback-engine-002, playback-engine-005]
spec_ref: "SPEC.md#local-state-per-playlist"
---

## Description

Extend `AudioPlayer.load(url:duration:autoplay:)` (`Sources/PlaylistBar/AudioPlayer.swift`) to
accept an optional start position, seeking the newly-loaded item there instead of always starting
at 0:00. Includes the near-end clamp: if the requested start position is within ~5 seconds of the
track's known duration, start at 0:00 instead of a few seconds of playback followed by an
near-instant auto-advance.

## Acceptance criteria

- `load(url:duration:startTime:autoplay:)` (or equivalent signature) with a `startTime` mid-track
  begins playback at approximately that position (verified via `currentTime` shortly after load).
- Omitting `startTime` (or passing `nil`/`0`) behaves exactly as today — starts at 0:00 — no
  regression to existing callers.
- A `startTime` within ~5 seconds of `duration` is clamped to 0:00 instead of honored literally.
- The existing trusted-duration end-of-track watchdog (`playback-engine-005`) still fires correctly
  measured from real elapsed playback time, unaffected by an initial seek.

## Notes

Uses the same trusted yt-dlp-provided `duration` this method already receives for the
end-of-track watchdog — no new data source needed for the near-end clamp.

`AVPlayer.seek(to:)` is already used elsewhere in this file (`restart()`, for BGM's Reset,
`bgm-008`) — reuse the same mechanism, just with a non-zero target instead of `.zero`.

Callers (`playback-controller-006`, `bgm-012`) are responsible for deciding *whether* a saved
position applies to the track being loaded (e.g. a fresh, never-before-played track has no saved
position and should pass `nil`) — this issue only covers the mechanics of seeking once a start
time is given.

## Fix / Implementation notes (2026-08-11)

`load(url:duration:startTime:autoplay:)` gained the `startTime` parameter (default `nil`, so
every existing caller is unaffected — verified via `swift build`, all three current call sites in
`PlaybackController.swift` compile unchanged). The seek is issued right after
`replaceCurrentItem`, same pattern already used by `restart()`. Near-end clamp threshold is
`duration - 5s`; verified via a standalone script covering: mid-track resume, at/just-inside/
just-outside the clamp boundary, `nil`/`0` startTime (no-op, matches pre-existing behavior), and
no-known-duration (never clamped, honored literally). `/code-review` couldn't be run (agent-
invocable only via explicit user run, no GitHub remote for `/review` either, per this repo's
existing documented limitation) — did a manual self-review pass instead, same convention as every
other issue in this codebase pre-git.
