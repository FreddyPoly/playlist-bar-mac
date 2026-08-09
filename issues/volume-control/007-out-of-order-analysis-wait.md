---
id: volume-control-007
title: Bounded wait for loudness analysis on out-of-order jumps
status: done
security: false
owner: agent
depends_on: [volume-control-003, volume-control-004, volume-control-005]
spec_ref: "SPEC.md#volume--loudness-normalization"
---

## Description

Handle the case `volume-control-006`'s preload can't cover: jumping straight to a track with no
cached gain and no preload head start (clicking a track in the list, Previous, or switching
playlists). Playback should briefly wait for analysis rather than start unnormalized, but must
never hang.

## Acceptance criteria

- Starting playback on a track with no cached gain and no in-flight preload for it triggers
  analysis (`volume-control-003`) and waits for it to complete before audio starts, up to a
  bounded timeout (implementation picks a concrete value — a few seconds is consistent with how
  long a single-pass `ffmpeg` analysis of a full track realistically takes on this app's expected
  network conditions; not specified further in SPEC.md).
- If analysis completes within the timeout, playback starts with the correct normalization gain
  applied from the first sample (via `volume-control-005`).
- If analysis fails or doesn't complete within the timeout, playback starts anyway at gain `1.0`
  (unnormalized) rather than continuing to wait — consistent with this app's existing
  never-block-indefinitely behavior (e.g. `TrackAvailabilityResolver`'s bounded skip pass).
- A timeout/failure is **not** cached as a permanent state on the track — the next time that
  track is played (in-order or out-of-order), analysis is attempted again from scratch.
- This wait uses the same `switchGeneration`-guarded pattern `PlaybackController` already uses
  elsewhere, so a superseded jump (e.g. user clicks a second track before the first's analysis
  wait resolves) can't apply a stale result.

## Notes

Added 2026-08-09. This is the one place normalization adds real, user-visible latency by design
(per the interview decision to prioritize correctness over speed for out-of-order jumps) — see
`volume-control-008` for surfacing that wait in the UI so it doesn't look like a frozen app.

**Implemented 2026-08-09**: in `play(startingAt:generation:)`'s `.playable` case, if the resolved
track has no cached gain, sets `isAwaitingLoudnessAnalysis = true` and awaits
`LoudnessGainCoordinator.gain(for:url:playlistSlug:timeout:)` (5s timeout — a concrete value this
issue's Notes flagged as unspecified by SPEC.md, picked as reasonable for a single-pass analysis
under normal conditions) before applying volume and loading the track. Because `play()` is the one
function every track-start path funnels through (manual jumps, `reset()`, cold-start
`togglePlayPause()`, *and* `advanceOnFinish`'s no-preload-ready fallback), this single change
covers both this issue and `volume-control-006`'s "same fallback path" note — no separate
implementation needed for the auto-advance-fallback case.

The `switchGeneration` guard needed care: an early version set `isAwaitingLoudnessAnalysis = false`
unconditionally right after the wait, *before* checking whether this call was superseded — which
would let a stale call clobber a newer call's still-genuinely-waiting state. Fixed by (1) resetting
the flag at the same optimistic entry point that already sets `currentIndex`/`isResolvingTrack`
(guaranteeing every *new* call clears stale state for itself, regardless of what an older call is
mid-way through), and (2) moving the post-wait `guard generation == switchGeneration else { return }`
*before* the reset, so a superseded call never touches shared state on its way out — mirrors the
exact pattern this method already uses for `isResolvingTrack`. Reasoned through by hand and matched
against that existing, already-relied-upon pattern; a standalone script modeling the same race hit
an unrelated deadlock in the script harness itself (blocking-wait interaction with Swift
concurrency in script mode, not a defect in the logic) and was abandoned in favor of this
comparison — flagging honestly rather than claiming a scripted verification that didn't actually
complete. Reviewed manually in place of `/code-review` (no git repo yet); no other issues found.

## QC feedback (2026-08-09, found during playback-engine QC)

**Scenario tested:** letting a track play to its natural end and confirming auto-advance (this
is actually `playback-engine`'s scenario, not this feature's — see below for why the bug
surfaced there instead of in `volume-control`'s own QC, which hadn't run yet).

**Expected:** advance to the next track, at most a few seconds' wait if that track needed fresh
loudness analysis (per this issue's bounded-timeout design).

**Actual:** the loading spinner got stuck indefinitely — no audio, no advance, no error, until
manually investigated.

**Root cause, confirmed via live diagnostic logging (temporary, removed once resolved) plus a
standalone timing script:** `LoudnessGainCoordinator.gain(for:url:playlistSlug:timeout:)`'s
original implementation used `withTaskGroup` to race the real analysis against a timeout. That's
structurally wrong for this use case — **a task group waits for *every* child task to finish
before it returns control to its caller, even a "loser" branch that's already been signalled via
`cancelAll()`**, because cancelling the group's wrapping child task doesn't cancel the externally-
stored `task` itself (`await task.value` doesn't observe that cancellation at all — it's not part
of the group's structured hierarchy). So the "timeout" was illusory: the call wouldn't actually
*return* until the real `ffmpeg` analysis finished, however long that took — confirmed directly
with a standalone script (`verify_timeout_latency.swift`): racing a 2s task against a 200ms
timeout returned the *correct value* (`1.0`) but only after the full ~2.1s, not ~0.2s. The
earlier scratch-script verification for this issue only asserted the *returned value* was
correct, never the *wall-clock latency* — which is exactly where the bug was hiding; flagging
this gap in my own prior verification honestly rather than glossing over it.

Real-world impact was worse than the 2s test case: live logging showed real `ffmpeg` analysis
passes on this machine taking 3–6+ seconds each (network + decode time for a full track), so any
track needing fresh analysis genuinely blocked playback for that entire duration — indistinguishable
from "frozen" to a listener with no progress indication.

**Fix:** replaced the `withTaskGroup` race in `gain(for:url:playlistSlug:timeout:)` with a
`withCheckedContinuation`-based race — two independent, unstructured `Task`s (inheriting this
class's `@MainActor` isolation, so the shared `hasResumed` guard needs no separate lock) each
resume the continuation if they're first; whichever loses keeps running to completion
independently in the background exactly as intended, but the function itself now returns as soon
as *either* side resolves. Re-verified via a corrected standalone script: the 2s-task-vs-200ms-
timeout case now returns in ~0.2s (not ~2.1s), and the slow task still completes and reports its
real result afterward; a fast-task-vs-2s-timeout case still returns in ~10ms, not 2s.

**Live re-verification:** rebuilt with temporary debug logging (removed after), ran via
`swift run` so output was visible, and reproduced real analysis passes taking 5–6s each — the
wait now correctly bounds at ~5s (the configured timeout) and returns the `1.0` fallback promptly
in that case, with the real analysis completing shortly after in the background and getting
cached correctly for next time (confirmed via log: a track whose wait timed out at gain `1.0`
showed its real measured gain arrive ~1s later, still updating `tracks` in memory via
`onGainMeasured`). User confirmed live: "Works correctly now" after the fix, across several
tracks and auto-advances.

**Not reopening `playback-engine-002`/`005` or any `playback-engine` issue** — investigated first
per the `qc` skill's guidance to check whether a failure actually belongs to the feature under
test before attributing it there; this one clearly doesn't (nothing in `playback-engine`'s own
code changed or was at fault) — the interaction only *manifested* during a `playback-engine`
scenario because that's what exercises real natural-end auto-advance, and `volume-control-007`'s
wait sits directly in that path (`PlaybackController.play(startingAt:generation:)`, shared by
both features' logic).
