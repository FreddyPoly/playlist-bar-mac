---
id: playback-engine-005
title: Feedback/resilience for throttled stream delivery
status: done
security: false
owner: agent
depends_on: [playback-engine-001, playback-engine-002]
spec_ref: "SPEC.md#playback-engine"
---

## Description

Discovered during `menu-bar-ui`/`playback-engine` QC follow-up (2026-08-09): resolved YouTube
stream URLs can be severely throttled by YouTube's CDN on some networks. Measured directly against
a real track (`lR1t5iheb9o`, genuine duration 2:22 per `yt-dlp --print duration_string`): the
resolved `bestaudio[ext=m4a]` stream sustained only ~31KB/s download throughput — barely above the
~16–20KB/s a 128kbps AAC stream needs for real-time playback, leaving almost no buffering margin.
The track took ~4:44 of real wall-clock time (~2x its actual length) to finish playing.

Playback itself is not broken by this — `playback-engine-002`'s finish-detection and auto-advance
were verified to work correctly even under this condition, it just takes as long as the throttled
stream takes. But from the listener's perspective, a multi-minute silent stall with the same visual
state as normal playback (Play/Pause button still shows "Pause", no indication anything's wrong)
reads as the app being frozen/broken, which is a real, bad user experience for what's supposed to be
a background music player.

## Acceptance criteria

- `AudioPlayer`/`PlaybackController` exposes a "stalled/buffering" signal, detected from a real
  playback stall (not just "any brief network jitter") — distinguishable from ordinary
  actively-playing state, so a consumer (see `menu-bar-ui-006`) can surface it. This issue owns
  *detecting* the stall; `menu-bar-ui-006` owns turning it into something visible in the dropdown.
- Investigate whether a different yt-dlp extraction strategy (format selection, player-client
  args, etc.) reduces the frequency/severity of throttling — not guaranteed to pan out (an initial
  attempt at `--extractor-args "youtube:player_client=ios"` and `=android` both failed to offer the
  `m4a` format for the test video), but worth a real attempt during implementation rather than
  ruling out upfront.
- Whatever's added must not regress normal (non-throttled) playback — most tracks on a decent
  network won't hit this at all, and the added logic shouldn't introduce false-positive "buffering"
  flicker during ordinary brief network jitter.
- No change to the wrap-around/skip/finish semantics already covered by `playback-engine-002/003/004` —
  this issue is about *detecting* a slow stream, not changing what happens once it does finish.

## Notes

This is an accepted-risk area per SPEC.md's Security section ("extracting playable stream URLs via
yt-dlp ... inherently fragile ... YouTube changes can break yt-dlp's extractors at any time") — the
goal here isn't to eliminate CDN throttling (not something this app controls), just to make a stall
detectable instead of silently indistinguishable from a bug, and to make a reasonable best-effort
attempt at avoiding it where possible.

**Scope note (2026-08-09):** originally this issue's acceptance criteria also covered the UI side
directly ("some way to distinguish playing from stalled/buffering in the UI"). Split that out to
`menu-bar-ui-006` once a broader SPEC.md decision landed covering loading feedback for playlist
switches and fresh-track resolution too, not just throttling stalls — this issue now owns detection
only, `menu-bar-ui-006` owns all the visible feedback (including for the signal this issue exposes).

## Fix (2026-08-09)

**The "throttling" framing above turned out to be wrong** — corrected in `playback-engine-002`'s
Notes too, since that issue's QC-failure diagnosis rested on the same mistaken conclusion. Real
root cause, found while implementing this issue: YouTube serves resolved audio as a progressively-
streamed, "not optimized" (moov-atom-at-end) M4A. `AVFoundation` has to estimate duration before
it's read enough of the file to know the real one, and that estimate is reproducibly **~2x too
long** — confirmed by fully downloading a real stream and inspecting it with `afinfo` (genuinely
142.31s, entirely correct) versus `AVFoundation`'s own reported duration for the same streamed URL
(284.68s). `Content-Length` itself is correct and matches the real file exactly, ruling out a
throttling/network explanation; most likely a channel-count/bitrate misdetection.
`AVURLAssetPreferPreciseDurationAndTimingKey` (the documented API for exactly this class of
problem) does not fix it — returns the same wrong value near-instantly, without reading more data.
Confirmed with the user directly: real audio plays correctly for the track's true length, then
genuinely goes silent, while `AVPlayer` continues reporting `rate == 1` and `currentTime` advancing
at real-time pace regardless — i.e. nothing in `AVFoundation`'s own model believes anything is
wrong, so there's no stall to detect from its perspective either.

**Acceptance criteria, addressed:**

- **Stalled/buffering signal** — added `AudioPlayer.isBuffering`, driven off
  `AVPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate` (the API `AVFoundation` itself uses
  internally to distinguish "actively playing" from "waiting for data," avoiding a reinvented,
  jitter-prone heuristic). Mirrored onto `PlaybackController.isBuffering` via a
  `setOnBufferingChange` callback (matching the existing `setOnFinish` callback convention, not
  Combine — this codebase doesn't use `.sink`/`AnyCancellable` anywhere, so a plain closure stays
  consistent). Ready for `menu-bar-ui-006` to consume. Note this signal did *not* end up being what
  fixes the original QC symptom (see above — `AVFoundation` never considered itself stalled), but
  it's still real, correct, useful signal for genuine network stalls elsewhere.
- **Alternate extraction strategy investigated for real:** tried yt-dlp's `ios`, `android`, `tv`,
  `web_safari`, `mweb`, and `android_vr` player-clients against the same real video. Every one is
  currently blocked by YouTube's newer anti-bot measures in this yt-dlp version (`2026.07.04`,
  already latest stable) — PO token requirements, DRM enforcement, or a SABR-only streaming
  experiment — worse than the default client, not better. No viable mitigation found right now;
  revisit if yt-dlp ships something new here.
- **The actual fix** (not originally anticipated by this issue's acceptance criteria, but what
  actually resolves the real problem): `StreamResolver.resolve(videoID:)` now also returns the
  video's real duration via yt-dlp's own metadata (`--print "%(duration)s"` piggybacked onto the
  same `-g` call, no extra process spawn), threaded through `PlayableResolution` and
  `NextTrackPreloader` to `AudioPlayer.load(url:duration:autoplay:)`. `AudioPlayer` arms a
  wall-clock `Timer` watchdog (not `AVPlayer`'s own broken duration) that fires `onFinish` once
  real elapsed playback time reaches `duration + 2s` grace — bypassing `AVFoundation`'s unreliable
  duration entirely rather than trying to correct it. Guarded against double-firing alongside the
  canonical `AVPlayerItemDidPlayToEndTime` notification (whichever arrives first wins) the same way
  the original (reverted) near-end-stall attempt in `playback-engine-002` was, this time grounded
  in a trustworthy duration instead of `AVFoundation`'s own bad one.
- **No regression:** verified via a standalone script that a normal, non-broken completion still
  fires exactly once through the canonical path (the watchdog's threshold sits past where real
  playback naturally ends, so it never gets there first in the working case).

**Verified against the real, previously-broken track** (`lR1t5iheb9o`, true duration 142s):
`onFinish` now fires at **145.0s** — matching the trusted duration plus grace — instead of the
previous **284.7s**. Confirmed a second time live in the actual packaged app by the user: "track
finished and it advanced correctly."
