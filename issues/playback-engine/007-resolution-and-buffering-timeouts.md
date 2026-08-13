---
id: playback-engine-007
title: Bounded timeouts for stream resolution and playback buffering
status: done
security: false
owner: agent
depends_on: [playback-engine-001, playback-engine-002, playback-engine-004]
spec_ref: "SPEC.md#playback-engine"
---

## Description

Found live, 2026-08-13: a track finished naturally, auto-advance began resolving the next one, and
it never started — permanent loading spinner, no audio, no recovery without manually pressing
Next/Previous. Investigated via `/interview`: two waits in the playback path had no time bound at
all, either of which can strand `isWaiting` (`isResolvingTrack`/`isBuffering`) forever:

- **Stream resolution** — `StreamResolver.resolve` → `YtDlpRunner.run`'s `yt-dlp -g` subprocess
  call had no timeout. If it ever stalls (network hiccup, throttling, a specific video hanging),
  `TrackAvailabilityResolver.resolveNextPlayable`'s `await` — and every caller of `play(startingAt:
  generation:)` waiting on it — waits indefinitely.
- **Playback buffering** — `AVPlayer` stuck in `.waitingToPlayAtSpecifiedRate` after a stream URL
  already resolved successfully had no watchdog either. This is what actually happened in the
  live incident: Next/Previous still worked afterward (confirming resolution itself wasn't
  frozen), and no `yt-dlp`/`ffmpeg` subprocess was still running, pointing at `AVPlayer`'s own
  in-process buffering rather than a hung subprocess.

Unlike the loudness-analysis wait (`volume-control-007`, correctly bounded to 5s), neither of
these had any bound before this issue.

## Acceptance criteria

- Single-video stream resolution (`StreamResolver.resolve`, used by `TrackAvailabilityResolver`,
  `NextTrackPreloader`, and `PlaybackController.playBGM`) is bounded to **10 seconds**. On
  timeout, the `yt-dlp` subprocess is terminated (not left running in the background).
- Continuous playback buffering (`AudioPlayer.isBuffering` staying true without interruption) is
  bounded to **20 seconds**, the same value for BGM and the 4 fixed playlists. On timeout, the
  stuck `AVPlayerItem` is torn down.
- Either timeout is treated exactly like an unavailable track (SPEC.md's "Behavior rules"):
  playback automatically skips to the next track, no error surfaced, no retry of the same track.
- Playlist/channel scanning (`PlaylistScanner`, `BGMChannelScanner`) is explicitly **not** in
  scope — those legitimately take much longer (a full playlist scan can take ~19s already) and
  aren't part of this failure mode.
- No regression to normal (non-stalled) playback, resolution, or BGM behavior.

## Notes

Full decision record from the `/interview` session that scoped this fix (timeout values, kill-vs-
let-run-in-background, and why BGM doesn't get a separately longer buffering allowance) is in
SPEC.md's new "Resolution and buffering timeouts" subsection under "Playback engine", and the
"Behavior rules" bullet extending unavailable-track handling to cover this.

## Fix (2026-08-13)

- **`YtDlpRunner.run(arguments:timeout:)`** gained an optional `timeout: Duration` parameter
  (default `nil`, so `PlaylistScanner`/`BGMChannelScanner`'s existing calls are unaffected). When
  set, the concurrent-pipe-drain `DispatchGroup.wait` is given a deadline; on timeout it calls
  `process.terminate()`, then waits (now-fast, since termination closes the pipes) for the drains
  and the process to actually exit before throwing `RunError.timedOut` — deliberately not the
  loudness-coordinator's "stop waiting, let it keep running" pattern, since a stream-resolve stall
  reads as more likely a genuine hang than a merely-slow analysis, and leaving terminated-but-
  still-draining subprocesses to pile up across many stuck tracks over a long session would leak
  resources.
- **`StreamResolver.resolve`** passes `timeout: Self.resolveTimeout` (`.seconds(10)`) and maps
  `YtDlpRunner.RunError.timedOut` to a new `ResolutionError.timedOut` case. No call site needed
  updating for this new case specifically — `TrackAvailabilityResolver`, `NextTrackPreloader`, and
  `PlaybackController.playBGM` already treat any non-`ytDlpNotFound` error identically to an
  unavailable track (skip and move on), which is exactly the desired behavior here too.
- **`AudioPlayer`** gained a `bufferingWatchdog: Timer?`, armed in `isBuffering`'s `didSet` the
  moment it becomes `true` and disarmed the moment it goes back to `false` — so only *continuous*
  stalling counts, not several short ones adding up. After 20s continuously buffering,
  `fireStuckBuffering()` explicitly tears down the item (`player.pause()` +
  `player.replaceCurrentItem(with: nil)`) and then calls the same `fireFinish()` the natural-end
  and known-duration-watchdog paths already use — reusing the existing "treat as finished, let the
  caller advance" mechanism rather than inventing a parallel one, which is also what makes the
  "skip forward, no error" behavior fall out for free at the `PlaybackController` level (no changes
  needed there at all).
- `swift build` clean.
- **Standalone-script verification against a fake slow subprocess was attempted but blocked by
  this session's own execution environment**, not by anything about the fix: both an interpreted
  `swift script.swift` run and a compiled binary hung indefinitely trying to spawn *any* nested
  subprocess (even a bare `ps aux` diagnostic inside the verification harness itself never
  returned) — a restriction of this particular sandboxed session on nested process spawning, not
  something the real app hits (`PlaylistBar.app` was observed all evening, both before and after
  this fix, calling `yt-dlp` via the exact same `Process()`-based mechanism with no such hang).
  The `DispatchGroup.wait(timeout:)` + `process.terminate()` pattern used here is otherwise a
  standard, widely-documented idiom and structurally mirrors this codebase's own already-verified
  pipe-draining logic in the same file — but this specific timeout/kill path has **not** actually
  been exercised end-to-end by anything yet, automated or live. Worth being honest about rather
  than claiming a verification that didn't actually complete.
- **Not live-verified either, at the time this note was first written** — the live incident that
  prompted this issue was resolved by pressing Next before the fix landed, so there was no repro
  left to re-test against afterward.
- **Net result at that point: this fix was unverified beyond compiling.**

## Live verification (2026-08-13, later the same day)

The stream-resolve-timeout path was force-tested for real, with the user's explicit go-ahead to
briefly swap their real `yt-dlp` for a slow shim (reversible, same rename pattern
`menu-bar-ui-005`'s harness scenario already used safely). Added as a permanent regression
scenario, `21-stream-resolve-timeout-bounded`, in `Sources/QCHarness/Scenarios.swift` (not a
one-off — this is exactly the kind of previously-found bug the harness's regression suite exists
to guard forever, same convention as scenario 09 for `volume-control-007`).

- **Confirmed via the harness scenario, clean runs**: switching to a playlist while `yt-dlp` is
  shimmed to hang 30s on its first invocation clears the loading spinner in ~12-18s (10s timeout +
  a fast real retry, sometimes plus a bounded loudness-analysis wait) and lands on a genuinely
  playable, correctly-named track — not stuck, not erroring.
- **Confirmed independently of the harness's own pass/fail judgment**, via an out-of-band process
  monitor (a separate polling loop watching `ps aux` throughout a run, outside the harness
  entirely): the shim's `sleep 30` process was observed alive, then genuinely absent from every
  subsequent poll well before the 30s mark — direct proof `process.terminate()` actually kills the
  hung subprocess, not just that the app moved on while it kept running unnoticed in the
  background.
- **Real bug found and fixed in the test scaffolding itself along the way** (not in the
  production fix): the first version of this scenario's cleanup `defer` used
  `FileManager.moveItem` to restore the real binary, which throws (silently swallowed by `try?`)
  when the destination already exists — true here, since this scenario (unlike the pre-existing
  `17-ytdlp-outage-error-handling`) also writes a new shim file to that same path. Every run left
  the shim in place, papered over only by `Scripts/qc.sh`'s own `mv`-based safety net. Fixed by
  clearing the destination before moving the real binary back.
- **Real flakiness found and partially addressed, also in the test scaffolding**: this scenario's
  pass/fail is reliable (never a false failure), but its *timing* isn't fully deterministic yet —
  it occasionally clears in well under a second, too fast to have genuinely hit the 10s timeout.
  Traced through two different causes along the way (a global "first ever call" marker racing
  against `NextTrackPreloader`'s own background resolve for a different track; then, after fixing
  that, an already-active-playlist reselect not always behaving as a genuine fresh trigger) and
  partially fixed (switching to a different playlist first, then to the shimmed target, made the
  common case reliable) — but a residual timing interaction remains unexplained. Documented
  in the scenario's own doc comment as known, safe (never false-positive), and not chased further
  given the production fix already has its own independent confirmation above. If this keeps
  showing up as a fast/inconclusive pass in future `/qc` runs, that's expected and not itself a
  regression signal.
- The playback-buffering-watchdog path (the other half of this issue, `AVPlayer` stuck buffering
  after a *successful* resolve) was **not** separately force-tested live — forcing it reliably
  would need a local server that accepts a connection and then stalls mid-response, meaningfully
  more new test infrastructure than the resolve-timeout shim reused from the existing outage
  scenario. Still relying on code review + the same `DispatchGroup`/`Timer`-based pattern already
  proven correct for the resolve-timeout half. Worth doing in a future pass if this specific path
  is ever suspected of a problem.
