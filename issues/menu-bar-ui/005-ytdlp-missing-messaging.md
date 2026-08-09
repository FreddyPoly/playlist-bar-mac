---
id: menu-bar-ui-005
title: yt-dlp missing / unavailable messaging
status: done
security: false
owner: agent
depends_on: [app-shell-003, playlist-data-002, playback-engine-001]
spec_ref: "SPEC.md#ui-menu-bar-dropdown"
---

## Description

If yt-dlp is not found on PATH (app-shell-003), or a playlist scan/stream resolution fails
outright, surface a clear in-dropdown message (e.g. "yt-dlp not found — run `brew install
yt-dlp`") instead of a silently broken or blank UI.

## Acceptance criteria

- With yt-dlp absent from PATH, launching the app shows the guidance message in the dropdown
  rather than crashing or appearing empty.
- Once yt-dlp is installed and the app is relaunched (or the check is retried), normal operation
  resumes and the message disappears.
- A playlist scan or stream resolution failure (yt-dlp present but erroring) shows a distinct,
  understandable message rather than the app appearing to hang.

## Notes

Wired `YtDlpLocator.checkAvailability()` into `ContentView` via a `.task` modifier (running it off
the main thread through `Task.detached`, finally addressing app-shell-003's own noted follow-up
about not blocking the UI thread with this blocking subprocess call). When unavailable, shows
"yt-dlp not found — run `brew install yt-dlp`, then relaunch." above the rest of the UI.

For the "scan or resolution failure shows a distinct message" half of this issue, had to extend
two already-`done` pieces, since neither had any way to surface a failure before now:
- `PlaylistLoader` (playlist-data-003) gained `@Published private(set) var lastScanErrorMessage:
  String?`, set in `rescanAndStore`'s catch block (previously it just silently `return`ed on
  failure) and cleared on the next successful scan.
- `PlaybackController` (playback-controller-001 onward) gained `@Published private(set) var
  errorMessage: String?`, set when a fresh-scan comes back empty with a loader error, or when
  `play(startingAt:)`'s resolution step throws — previously silenced via `try?` and treated
  identically to "every track is unavailable" (a real `TrackAvailabilityResolver.PlayableResolution
  .noneAvailable` case, not an error). These are now distinguished: `.noneAvailable` still just
  clears `currentIndex` with no message (it's not an error), while an actual throw sets a message.

**Bug caught and fixed before it shipped:** the first version of the `play(startingAt:)` catch
clause matched `YtDlpRunner.RunError.ytDlpNotFound`, but `StreamResolver.resolve` catches that and
rethrows its own `StreamResolver.ResolutionError.ytDlpNotFound` — the original clause would never
have matched, silently falling through to the generic message instead of the specific
"run `brew install yt-dlp`" one. Caught this by re-reading `StreamResolver.swift` before testing
rather than assuming the error type, and fixed it to catch the actual thrown type.

**Message wording fix:** the first version of both generic fallback messages interpolated the raw
error directly (`"Couldn't load this playlist (\(error))."`), which for a real yt-dlp failure
dumps several lines of raw stderr (HTTP retry warnings, etc.) into the UI — the opposite of "a
clear, understandable message." Replaced both with concise, generic text
("check your network connection") instead of exposing internals.

Verified end-to-end (not just each piece in isolation): switching to a playlist with a genuinely
broken URL correctly set `controller.errorMessage` to the concise message, `tracks`/`currentIndex`
stayed empty/nil, and the app didn't crash or hang; switching to a real playlist afterward
correctly cleared it back to `nil`. Confirmed the real `YtDlpLocator.checkAvailability()` check
(now that yt-dlp is genuinely installed) still returns `.available` as expected. Did not re-test
the actual "yt-dlp absent" UI path live, since yt-dlp is now genuinely installed on this machine
via the earlier `brew install` — that underlying detection logic was already thoroughly verified
in app-shell-003 (before installation) and in the PATH-fix work after; this issue only adds the
UI display on top of an already-proven check.

Same visual-verification limitation as the other menu-bar-ui issues for the actual rendered
message text/styling — confirmed via build + runtime behavior, not a screenshot.

## QC feedback (2026-08-09)

**Scenario tested** (during playlist-data QC, scenario 4: "failed background refresh doesn't wipe
a working cache"): with a stale (backdated >24h) Rock3 cache on disk and `yt-dlp` temporarily
removed from PATH (app already running, not relaunched), switched to Jazz then back to Rock3 to
trigger the stale-cache background-refresh path plus a fresh play attempt.

**Expected**: per this issue's own acceptance criteria, a resolution/scan failure should show "a
distinct, understandable message" without the UI appearing broken or blank; the underlying cached
track list should remain usable.

**Actual**: two problems, confirmed by reading `Sources/PlaylistBar/ContentView.swift` and
`Sources/PlaylistBar/PlaybackController.swift` against what the user saw:

1. **Duplicate error messages.** `ContentView` renders its own "yt-dlp not found — run `brew
   install yt-dlp`, then relaunch." banner (from the `.task`-driven `YtDlpLocator
   .checkAvailability()` check) *and*, simultaneously, `PlaybackController.errorMessage` gets set
   to a near-identical second message ("yt-dlp not found — run `brew install yt-dlp`") in
   `play(startingAt:)`'s `catch StreamResolver.ResolutionError.ytDlpNotFound` block
   (`PlaybackController.swift:280-287`). Both conditions are true at once whenever yt-dlp goes
   missing while a track is actively being resolved, so the user sees two near-identical red
   banners stacked on top of each other instead of one.
2. **Track list disappears entirely, not just playback.** That same catch block sets
   `currentIndex = nil` (`PlaybackController.swift:284`) on a resolution failure. `ContentView
   .displayedTracks` (`ContentView.swift:147-153`) requires a non-nil `currentIndex` to return
   anything, so this clears the *entire* track list from view — even though `tracks` (the actual
   cached playlist data) is still fully populated in memory and correct on disk. The user reported
   "no displayed track list" for both Jazz and Rock3, matching this: the visible symptom is a
   blank list, not merely "not currently playing."

**Root cause is here, not in playlist-data**: verified directly that the on-disk cache file
(`rock3.json`) stayed fully intact (2,448 tracks, timestamp unchanged) throughout — playlist-data's
"failed refresh doesn't wipe the cache" guarantee holds. The bug is purely in how this issue's
error-display logic reacts to a resolution failure: it should probably keep showing the cached
`tracks` list (so the user can see what's available and still click another track, e.g. one
already preloaded, or at least understand why nothing plays) rather than nulling `currentIndex`
and hiding the list — and the two error-message sources (`ContentView`'s own availability check vs.
`PlaybackController.errorMessage`) should be reconciled into one, not shown together.

## Fix (2026-08-09)

Two independent, targeted changes, matching the two symptoms above:

1. **Duplicate messages** — `ContentView.swift`'s two message blocks are now `if`/`else if`
   instead of two independent `if`s: the yt-dlp-availability banner (broader signal, includes the
   "then relaunch" guidance) takes priority, and `controller.errorMessage` only renders when that
   banner isn't already showing — since a missing yt-dlp is what drives `controller.errorMessage`
   into its yt-dlp-not-found state in the first place, showing both was always redundant, never two
   genuinely different problems at once.
2. **Track list disappearing** — `PlaybackController.play(startingAt:)` now sets `currentIndex =
   index` optimistically *before* attempting resolution (previously only set on success), and no
   longer nils it back out in either catch block on failure. `ContentView.displayedTracks` reads
   directly off `currentIndex`/`tracks`, both already correct at that point, so the list now stays
   visible (centered on the intended track) through a resolution failure instead of vanishing —
   `tracks` was never the problem, only `currentIndex` being nulled was. The `.noneAvailable`
   branch (genuinely no playable track exists) is unchanged and still clears `currentIndex`, which
   is correct there — that's the one case with nothing sensible to highlight.

Verified end-to-end against the real packaged app, reproducing the exact original QC scenario:
relaunched with `yt-dlp` removed from PATH from the start, restored the last Rock3 session (no
auto-play, per startup-002), then pressed Play to force a resolution attempt. Confirmed with the
user: exactly one red message shown (not two), and the track list stayed visible and correctly
populated throughout. Restored `yt-dlp` and relaunched again: message disappeared, track list and
transport controls resumed working normally — the originally-passing acceptance criteria (yt-dlp
absent at launch, yt-dlp restored + relaunch) were re-confirmed unaffected by this change.

`swift build` clean; no test suite exists in this project yet (see `app-shell-001`), so this was
verified manually against the running app per the project's established pattern for UI-facing
issues, not via automated tests.
