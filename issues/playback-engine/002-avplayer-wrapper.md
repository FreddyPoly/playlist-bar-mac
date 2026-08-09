---
id: playback-engine-002
title: AVPlayer wrapper for a resolved stream URL
status: done
security: true
owner: agent
depends_on: [playback-engine-001]
spec_ref: "SPEC.md#playback-engine"
---

## Description

Wrap `AVPlayer` to load and play a resolved audio stream URL, exposing play/pause/stop and a
completion callback for when a track finishes naturally (used by playback-controller-004 for
auto-advance).

## Acceptance criteria

- Given a resolved stream URL, audio plays through the system's default output.
- Pause/resume works correctly on the currently loaded item.
- A "did finish" callback/notification fires at the natural end of a track.
- Loading a new URL while one is already playing cleanly stops/replaces the previous item (no
  overlapping audio).

## Notes

**Security rationale:** streams network content from a URL derived from third-party (yt-dlp)
output — flagged per SPEC.md's Security section note on network access on behalf of the user.

Implemented as `AudioPlayer`, a `@MainActor` `ObservableObject` in
`Sources/PlaylistBar/AudioPlayer.swift` wrapping a single `AVPlayer`. `load(url:autoplay:)` swaps
in a new `AVPlayerItem` via `replaceCurrentItem`, which inherently prevents overlapping audio
(AVPlayer only ever has one current item). `setOnFinish(_:)` registers the completion callback,
backed by an `AVPlayerItemDidPlayToEndTime` observer (re-registered per item, torn down in
`stop()`/`deinit`/on the next `load`).

**Found and fixed a real bug in playback-engine-001 while verifying this issue** — see that
issue's Notes: the stream URLs it was resolving (WebM/Opus) never became playable in AVPlayer.
Fixed there; this issue's verification below is against the corrected M4A URLs.

Verified against real resolved streams (after the playback-engine-001 fix):
- `AVPlayerItem`'s duration loaded correctly (~479.6s, matching a real ~8 minute track) via the
  modern `asset.load(.duration)` API.
- `load(url:autoplay:true)` → `isPlaying` true; `pause()` → false; `play()` → true again.
- Loading a second URL while the first was playing succeeded with no crash and `isPlaying`
  remained true throughout — confirms clean replacement, no overlapping audio.
- **Real playback + finish callback**: seeked to 2 seconds before the track's actual end (via
  direct access to the underlying `AVPlayer` for the test only — the wrapper itself doesn't
  expose seeking, not required by this issue), called `play()`, and `onFinish` fired ~2.1 seconds
  later — i.e. actual audio playback advanced through real wall-clock time to the genuine end of
  the track and the completion notification fired correctly. This is meaningfully stronger
  evidence than just checking player state flags, since it proves audio is actually being decoded
  and played, not just that our wrapper's booleans flip correctly.

**Security review:** `/security-review` still requires a git repository (same limitation noted on
playlist-data-002/playback-engine-001). Manual pass: the wrapper only ever loads URLs handed to it
by the caller (ultimately from `StreamResolver`, already reviewed); it doesn't fetch, parse, or
execute anything itself beyond standard `AVPlayer` network streaming.

## QC feedback (2026-08-09, playback-engine feature QC)

**Scenario tested:** let a track play to its natural end in the real packaged app (full-length
real playback of a real Jazz/Rock3 track — not a seek-to-2-seconds-before-end like the original
dev verification above), with nothing else touched, expecting auto-advance to the next track per
SPEC.md's "Auto-advance" behavior rule.

**Expected:** the next track starts playing promptly (playback-engine-003's preload makes this
gapless), same as `playback-controller-004`'s wiring implies.

**Actual:** playback just stopped at the end of the track. No error message, no crash, no hang.
Confirmed via follow-up: the menu bar dropdown's Play/Pause button was still showing the "Pause"
icon (as if it still believed it was playing) even though audio had stopped and no track change
had happened — i.e. `PlaybackController.isPlaying` never flipped and `advanceOnFinish()` never
ran.

**Root-cause read (not yet fixed, just narrowed):** `PlaybackController`'s wiring
(`player.setOnFinish { ... advanceOnFinish() }` in `PlaybackController.swift:45-49`, and
`advanceOnFinish()` itself at `PlaybackController.swift:216-238`) reads correctly — it's a
straightforward "if preloaded, use it; else resolve fresh" and would work fine *if invoked*. The
symptom (stuck "Pause" icon, no advance, no error) matches the finish notification never firing at
all, which points at `AudioPlayer`'s `AVPlayerItemDidPlayToEndTime` observer
(`AudioPlayer.swift:21-31`) rather than the controller's advance logic. This issue's own original
verification only tested the callback by seeking to 2 seconds before a track's end and letting it
play out from there — it never tested a full-duration natural playthrough of a real multi-minute
googlevideo stream, so it wouldn't have caught a failure mode specific to long-running playback
(e.g. `AVPlayer`'s default `automaticallyWaitsToMinimizeStalling` causing a stall/rebuffer near the
true end of a long stream that never resolves into reaching the item's actual end, so
`AVPlayerItemDidPlayToEndTime` never posts).

**Not reopening `playback-controller-004`:** its wiring code looks correct and untestable-in-
isolation from this — the signal it depends on (the finish callback) never arrived, so there's
nothing yet pointing at a bug in the advance/orchestration logic itself. Revisit if fixing this
issue doesn't resolve the QC failure.

**Scope for the fix:** investigate why `AVPlayerItemDidPlayToEndTime` didn't fire (or the handler
didn't run) during a real full-length track's natural completion — likely needs either instrumenting
with debug logging against a real long track, or looking at `AVPlayer.automaticallyWaitsToMinimizeStalling`/
buffering behavior near end-of-stream for progressively-downloaded network audio.

## Fix (2026-08-09)

Investigated with live diagnostic logging (temporary, removed once resolved) directly in the
packaged app rather than guessing — a debug heartbeat `Timer` completely independent of AVFoundation
made it possible to see the process's own real-time behavior without needing screen access.

**Real fix applied:** added a `ProcessInfo.processInfo.beginActivity(options: [.userInitiated,
.idleSystemSleepDisabled], reason:)` token, held for as long as `AudioPlayer` is actively playing
(acquired in `play()`, released in `pause()`/`stop()`/on natural finish/in `deinit`). This is the
standard macOS API for telling the system not to App Nap (or idle-sleep) a process — relevant here
because this is an `LSUIElement` menu bar app with no visible window at any point, a prime App Nap
target once backgrounded. This is a real, worthwhile hardening fix on its own merits (a sufficiently
long idle background period could otherwise let the OS deprioritize the process's scheduling), even
though it turned out not to be the actual cause of the specific QC failure below.

**The actual root cause of the QC-observed "frozen" symptom, found via the same live diagnostics:**
not a code defect in this wrapper at all. `AVPlayerItemDidPlayToEndTime` does fire correctly, and
`PlaybackController.advanceOnFinish()` does correctly run and advance — verified three independent
ways: (1) an isolated bare-AVPlayer probe seeking near a track's end, (2) a standalone script
deterministically simulating a stall, and (3) a live full end-to-end run in the actual packaged app,
all consistent. What actually happened in the QC session: the specific track ("Alice Syndrome —
'Deep Dive'", confirmed via `yt-dlp --print duration_string` to genuinely be 2:22) took **4:44 of
real wall-clock time** — almost exactly double — to reach its natural end. Direct measurement
(`curl` against the resolved stream URL, twice, from the same machine/network) showed sustained
download throughput of only **~31KB/s**, barely above the ~16–20KB/s a 128kbps AAC stream needs for
real-time playback, leaving almost no buffering margin — i.e. genuine YouTube CDN throttling of the
resolved stream on this network, not an app bug. This matches SPEC.md's already-documented accepted
risk around yt-dlp/YouTube CDN fragility. Tried alternate yt-dlp player-clients (`ios`, `android`)
to see if a different extraction path avoided the throttling — neither offered the `m4a` format for
the test video, so this wasn't a quick fix and wasn't pursued further here.

**Acceptance criteria re-verified after the fix:** all four hold, including "did finish fires at
natural end" — confirmed correct even under the adverse real-world throttling condition above (it
just takes as long as the throttled stream takes).

Per user decision during QC follow-up, the throttling/stall-feedback problem itself (silent,
seemingly-frozen playback during a stall, even though it does recover) is tracked separately as a
new issue rather than folded into this one — see `playback-engine-005`.

**Correction (2026-08-09, found while implementing `playback-engine-005`):** the "CDN throttling"
diagnosis above is wrong and is left in place only as an honest record of how the investigation
went, not as the real explanation. Real root cause, confirmed conclusively: `AVFoundation`
computes a badly wrong duration estimate (~2x too long) for these YouTube audio streams — they're
served as a progressively-streamed, "not optimized" (moov-atom-at-end) M4A, and `AVFoundation` has
to estimate duration before it's read enough of the file to know the real one. Confirmed via
`afinfo` on a fully-downloaded real file (genuinely 142.31s, correct in every respect) versus
`AVFoundation`'s own reported duration for the same streamed URL (284.68s) — almost exactly double,
most likely a channel-count/bitrate misdetection (`Content-Length` itself is correct and matches
the real file exactly, ruling out a network/throttling explanation). Real playback genuinely goes
silent once the true content ends, while `AVPlayer` continues reporting `rate == 1` and advancing
`currentTime` at real-time pace regardless — i.e. its own internal model believes it's still
validly playing, so nothing here was actually broken from `AVFoundation`'s point of view; there was
just nothing left to correctly detect against. Fixed in `playback-engine-005` via a
trusted-duration watchdog fed by yt-dlp's own metadata (unaffected by this `AVFoundation`
duration-estimation bug) rather than trying to make `AVFoundation` estimate correctly — see that
issue for the fix and verification.

**Security re-review:** the only new code is the `ProcessInfo` activity token (no external input,
no new attack surface) — consistent with this issue's existing manual security review above.
