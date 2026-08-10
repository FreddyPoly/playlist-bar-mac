---
id: bgm-006
title: BGM switch-to + Next selection orchestration
status: done
security: false
owner: agent
depends_on: [bgm-003, bgm-004, bgm-005, playback-controller-001]
spec_ref: "SPEC.md#bgm-channel-playback"
---

## Description

Wire BGM into the playback controller as a selectable entry: switching to BGM loads the pooled
channel cache (`bgm-003`) and starts playing a selected video; pressing Next (or auto-advance on
natural end) picks a new video via `bgm-004`'s selection algorithm, plays it, appends it to the
session history (see `bgm-007`), and persists it as the resumable position.

## Acceptance criteria

- Selecting "BGM" from the playlist picker loads the pooled cache (instant if cached, per
  `bgm-003`) and starts playback of a video — the persisted last-played BGM video if one exists
  (see `bgm-009`), otherwise a fresh selection via `bgm-004`.
- Pressing Next, or a BGM video finishing naturally, picks a new video via `bgm-004` (excluding the
  video that was just playing), plays it, and records it as the new resumable position — same
  "persist on every track change" behavior the 4 fixed playlists already have
  (`player-state-001`), reusing that same per-slug storage with a `"bgm"` slug rather than
  building a parallel mechanism.
- Unavailable-video handling (deleted/private/region-locked) still applies the same way it does
  for the 4 fixed playlists — a video that fails to resolve is skipped in favor of another
  selection, not treated as a hard failure.
- Loudness normalization and master volume trim apply to BGM playback exactly as they do to
  regular tracks (no special-casing needed if BGM videos flow through the same playback path as
  regular tracks).
- Only one thing plays at a time — switching to or within BGM stops whatever was previously
  playing, same rule as the 4 fixed playlists.

## Notes

This issue deliberately covers only **switch-to** and **Next/auto-advance**. Previous
(`bgm-007`) and Reset (`bgm-008`) are separate issues since their semantics diverge further from
each other and from Next — keep this issue's scope to what's shared between initial selection and
forward progression.

BGM has no fixed playlist index, so this can't reuse `playback-controller-001`'s exact
index-stepping machinery — but it can and should reuse the same generation-guard pattern (against
overlapping/stale async calls) and the same persistence/Now-Playing-info plumbing that
`playback-controller-001` already established, rather than duplicating it.

## Implemented (2026-08-10)

**Key design decision**: BGM's "current track" is represented via the *existing*
`tracks: [CachedTrack]` / `currentIndex: Int?` mechanism — a single-element `tracks` array,
`currentIndex = 0` — rather than separate BGM-specific published state, with `currentPlaylist` set
to a synthetic `Playlist(slug: "bgm", name: "BGM", url: "")`. This is what makes
`updateNowPlayingInfo()`, the menu bar title (`PlaylistBarApp.menuBarTitle`), and
`applyEffectiveVolume()`/`currentTrackGain` all work correctly for BGM **with zero changes to any
of them** — none of those three integration points were touched, they just work off whatever
`tracks`/`currentIndex`/`currentPlaylist` happen to hold. `PlayerStateStore`'s existing per-slug
persistence (last-played track, last-active playlist) is reused directly with slug `"bgm"`, same
as the 4 fixed playlists — no new persistence mechanism needed there either.

Added to `PlaybackController`: `static let bgmPlaylistSlug`, computed `var isBGMActive` (derived
from `currentPlaylist?.slug`, not a separate flag, so it can't drift out of sync), `@Published
private(set) var bgmHistory: [BGMTrack]` (session-only, appended to on every successful BGM play —
consumed later by `bgm-007`/`bgm-011`), `func switchToBGM()`, and two private helpers:
`advanceBGM(generation:)` (shared by manual `next()` and the auto-advance branch of
`advanceOnFinish()` — same "one helper, two callers" shape `play(startingAt:generation:)` already
uses) and `playBGM(startingFrom:generation:)` (resolves + plays, with a bounded
retry-on-unavailable loop mirroring `TrackAvailabilityResolver`'s guarantee). `next()`,
`advanceOnFinish()`, and `switchTo(playlist:)` (to `cancel()` a still-armed `bgmListenTracker` when
leaving BGM — the wiring requirement `bgm-005` flagged) were all extended with `isBGMActive`
branches.

**Scope decisions made explicit rather than silently expanded or silently skipped** (SPEC.md says
Now Playing, master volume, and per-track normalization apply to BGM "exactly as regular tracks,
no special-casing" — none of the 11 `bgm-*` issues had explicitly broken that out, so judgment was
needed on how literally to take it here):
- **No BGM-specific next-track preloader.** Unlike the fixed playlists (`playback-engine-003`),
  BGM's next pick isn't decided until it's actually needed, so there's nothing to preload ahead of
  time without also building a "decide-the-next-pick-early-just-to-preload-it" mechanism, which
  wasn't required by any `bgm-*` acceptance criteria. Auto-advance therefore has a real (if
  usually brief) resolution gap for BGM, unlike the fixed playlists' gapless transition — flagged
  here as a known gap, not silently absorbed.
- **Simplified loudness normalization**: a standalone bounded-wait helper
  (`measureBGMGain(url:timeout:)`, same continuation-race shape as
  `LoudnessGainCoordinator.gain(for:url:playlistSlug:timeout:)` — deliberately *not*
  `withTaskGroup`, avoiding the exact bug documented in that type's own Notes) persists directly
  to `BGMCacheStore.setNormalizationGain` (not `PlaylistCacheStore` — see below for why that
  matters) on every BGM play whose track has no cached gain yet. No in-flight-task cache shared
  across calls (there's no preloader to share it with), so a timed-out-but-later-successful
  analysis isn't retroactively cached the way the fixed-playlist coordinator's is — a smaller,
  disclosed regression versus skipping BGM normalization outright.
- **Why `LoudnessGainCoordinator`/`NextTrackPreloader` couldn't just be reused as-is**: both are
  hardcoded to persist via `PlaylistCacheStore.setNormalizationGain(_:forVideoID:playlistSlug:)`.
  Passing `playlistSlug: "bgm"` would've silently written to a `PlaylistCacheStore`-managed
  `bgm.json` that's never created (no `PlaylistLoader.load` ever runs for slug `"bgm"`), so that
  call would silently no-op every time — real `ffmpeg` analysis would run, then its result would
  be thrown away, forever. Caught this during design, before writing any code, by actually reading
  `LoudnessGainCoordinator.swift`'s persistence call rather than assuming it was storage-agnostic.
- **Previous and Reset are safe no-ops for now** (`bgm-007`/`bgm-008`, not yet implemented) rather
  than letting the *old* index-based `step(by:)`/`play(startingAt: 0)` logic run against BGM's
  one-element `tracks` array — which would "work" in the sense of not crashing, but would silently
  bypass `BGMCacheStore`'s gain persistence, `bgmHistory`, and `bgmListenTracker`, corrupting BGM's
  own bookkeeping. A guarded no-op was judged safer than a subtly-wrong active behavior.
- `togglePlayPause()`'s resume-a-restored-track fallback branch (calls `play(startingAt:)`
  directly) is **not yet BGM-aware** — harmless today since `switchToBGM()` always autoplays, so
  `hasLoadedCurrentTrack` is always true immediately afterward, but this will need extending once
  `bgm-009` adds a restore-without-autoplay path for BGM. Flagging now so it isn't rediscovered
  from scratch later.

**Known minor UX gap, disclosed rather than silently left**: within `playBGM`'s retry loop, each
unavailable candidate briefly updates `tracks`/`currentIndex` (and therefore the menu bar
title/Now Playing info) before moving to the next candidate — unlike the fixed-playlist path,
where `TrackAvailabilityResolver` resolves entirely internally and `PlaybackController` only ever
publishes the *final* result. In the rare case of back-to-back unavailable BGM videos, the title
could briefly flicker through skipped candidates rather than jumping straight to the one that
actually plays. Judged acceptable given genuinely unavailable videos should be uncommon (the
channel scan already filters members-only, and duration comes from real flat-playlist metadata) —
not restructured to buffer state until final resolution, to avoid adding real complexity for a
rare edge case.

**Verification**: real `PlaybackController` methods can't be unit-tested directly (executable
target, no test framework — see `CLAUDE.md`'s convention), so this was verified via two standalone
scripts that mirror the actual control-flow shape with fakes standing in for already-independently-
verified externals (`StreamResolver`, `LoudnessAnalyzer`, `PlayerStateStore`): one exercising
`playBGM`'s retry loop (immediate success; skip-one-unavailable-then-succeed, confirmed via
"first call was the original candidate" + "last call is the one that actually played" rather than
assuming call order, since the retry pick between ties is genuinely random — an initial stricter
assertion caught this and was corrected, not a code bug; every-candidate-unavailable stops cleanly
with empty state and a bounded call count; `advanceBGM` never re-picks the current track across 50
samples) and one exercising `measureBGMGain`'s bounded wait (a fast fake analysis returns the real
value promptly; a slow one — exceeding the timeout — returns `nil` and the call itself returns
near the timeout rather than waiting for the slow analysis to actually finish, confirming this
doesn't reproduce `volume-control-007`'s `withTaskGroup` bug). All passed. `swift build` succeeds
with no warnings. The `tracks[0]`/`currentIndex`-reuse design for Now Playing/menu-bar-title/volume
integration was verified by code tracing (each of those three call sites read only
`tracks`/`currentIndex`/`currentPlaylist`, all correctly populated for BGM) rather than a live GUI
run, consistent with this project's existing "state verified via reasoning/prints, visual
rendering needs the user" limitation noted in `CLAUDE.md`.

**Review**: manual pass in place of `/code-review` (see `bgm-002`'s Notes). `security: false` — no
new subprocess/parsing surface beyond what `bgm-002`/`playback-engine-001` already introduced and
reviewed. No findings beyond the scope decisions and known gap already disclosed above.

## QC feedback (2026-08-10) — reopened

**Scenario tested**: first-time selection of "BGM" from the playlist picker (fresh channel scan,
no cache), per SPEC.md's "Switching playlists: ... starts playing immediately" and the BGM-specific
acceptance criterion above ("Selecting 'BGM' ... starts playback of a video").

**Expected**: playback starts within a few seconds, same as switching to any of the 4 fixed
playlists.

**Actual**: the app got stuck showing the loading spinner for **several minutes with no audio**,
reproduced twice live by the user (fresh app launch each time, real channel scan, real video pick).
Investigated live with temporary debug instrumentation added directly to `playBGM`/
`measureBGMGain` (reverted after diagnosis, not left in the codebase):

- The picked video was a genuine BGM pool member with `duration=3553s` (~59 minutes) — well within
  the pool's `duration >= 900` filter, but far longer than anything in the 4 fixed playlists (which
  this app's playback path has only ever been exercised against so far).
- `measureBGMGain`'s 5-second bounded wait **works correctly** — confirmed via instrumented logs:
  the timeout task fires at ~5s, the real (slow) `ffmpeg` analysis is correctly abandoned-but-left-
  running in the background, and `playBGM` proceeds to call `applyEffectiveVolume()` /
  `player.load(url:duration:autoplay:true)` within ~5 seconds of selection every time. This part of
  `bgm-006`'s own implementation is **not** the bug — no code change needed here.
- `AudioPlayer.load()`/`player.play()` genuinely get called on time. Confirmed via the system log
  (`log show --predicate "processID == <pid>"`) that `AVPlayer`'s own network layer opens a real
  connection and receives a successful `HTTP 206` response within seconds of `player.load` being
  called, and `nettop` confirmed bytes continuing to trickle in afterward (not a dead connection) —
  yet the UI stayed on the loading spinner for minutes past that point, confirmed directly by the
  user both times.
- Conclusion: `AVPlayer` itself is taking a very long time to become ready-to-play for this
  specific stream, independent of anything `bgm-006`'s own orchestration code does wrong. The likely
  cause is the same structural issue already documented in `AudioPlayer.swift`/
  `playback-engine-005` — YouTube serves these streams as progressively-downloaded,
  moov-atom-at-end M4A — but that issue was previously only observed to cause a **duration**
  miscalculation (2x too long) for normal, few-minutes-long fixed-playlist tracks, where playback
  itself still *starts* promptly. BGM's videos are a new, much longer regime (up to ~1 hour, no
  upper bound in the pool filter) that this codebase's playback path has never been exercised
  against before this QC pass — for a large enough file, locating/reading the trailing moov atom
  before `AVPlayer` can begin decoding anything may itself take a long time, independent of the
  already-known duration bug. Not confirmed as the exact mechanism (that would need deeper
  `AVFoundation`-level investigation, e.g. tracing exactly which byte ranges `AVPlayer` requests and
  how many round trips it takes before `timeControlStatus` leaves `.waitingToPlayAtSpecifiedRate`),
  but the video-length correlation and the "real data is flowing, just very slowly toward
  readiness" evidence both point here rather than at anything in `playBGM`'s own control flow.

**What to try when picking this back up**: this is likely a genuine gap in this feature's design,
not a small bug — options worth considering (not decided here): capping the BGM pool's eligible
video length at something well under an hour; picking a different yt-dlp format/itag that isn't
moov-atom-at-end for these specific streams if one exists; or accepting a real multi-second-to-
multi-minute startup latency for very long videos and making that legible in the UI (e.g. a
"this may take a while for long tracks" message) rather than an indistinguishable-from-frozen
spinner. Whichever direction is chosen, re-verify live against a real long (~30–60 min) video from
the actual configured channel, not just a standalone script — that's exactly the gap that let this
ship undetected (see `bgm-006`'s own "Verification" note above: all prior verification used fakes
standing in for `StreamResolver`/`LoudnessAnalyzer`/`AVPlayer`, never a real long-form stream
through the real player).

**Blocked as a result**: this QC pass could not proceed past the very first BGM scenario (selecting
BGM and having it start playing) — Next/Previous/Reset/history/restore-on-relaunch/listen-count
scenarios are all untested pending a fix here, since none of them are reachable without playback
actually starting.

## Fix (2026-08-10)

Ran an `/interview` to decide the direction (full decisions + rationale in `SPEC.md`'s "BGM
channel playback" — "Startup latency for long videos" — and "Volume & loudness normalization").
Decided: switch BGM (only) to yt-dlp's progressive/faststart format instead of audio-only DASH,
accepting extra bandwidth (confirmed not a concern for this local, unmetered-connection tool) for
reliably fast start regardless of video length. Per-track loudness normalization was dropped for
BGM as a direct consequence — analyzing a full hour-long combined AV stream with `ffmpeg` on every
first play was judged not worth the cost once nothing was blocked on it anymore.

**Changes**:
- `StreamResolver.resolve(videoID:preferProgressive:)` gained a `preferProgressive` parameter
  (default `false`, so the 4 fixed playlists and `NextTrackPreloader`/`TrackAvailabilityResolver`
  are untouched). When `true`, resolves via yt-dlp's `best[acodec!=none][vcodec!=none]` selector
  instead of `bestaudio[ext=m4a]/bestaudio`. `playBGM` passes `true`.
- `playBGM`'s entire loudness-analysis wait (the `measureBGMGain` call and its surrounding
  `isAwaitingLoudnessAnalysis` block) is deleted, along with the now-fully-dead
  `measureBGMGain(url:timeout:)` function itself. BGM tracks always construct with
  `normalizationGain: nil` — `currentTrackGain` already falls back to `1.0` for `nil`, so this
  needed no changes to shared volume code.
- `BGMTrack.normalizationGain` and `BGMCacheStore.setNormalizationGain` removed entirely
  (permanently dead after the above) — `BGMCacheStore.merge` no longer carries a gain field
  forward either. Backward-compatible: `Codable` synthesis ignores unknown JSON keys, so an
  existing `bgm-pool.json` with old `normalizationGain` entries decodes fine.
- `AudioPlayer.load()` gained an `itemTracksObserver` (KVO on `item.tracks`, mirroring the
  existing `timeControlStatusObserver` pattern) that disables any `.video` track on the loaded
  item once known — the app has no video surface anywhere, so BGM's now-present video track would
  otherwise be decoded for up to an hour for nothing. No-op for the 4 fixed playlists' audio-only
  items.

**Format-selector nuance found during verification, not assumed away**: `best[acodec!=none]
[vcodec!=none]` doesn't always resolve to the same format shape — tested against 3 real pool
videos and got legacy progressive MP4 (itag 18) for 2, and an HLS manifest (itag 96, `.m3u8`) for
1 (same video, resolved differently across separate calls — YouTube's own format availability
appears to vary per request for this content). Rather than assume this was fine, wrote a
standalone script (`AVPlayer` + KVO on `timeControlStatus`, timing to `.playing`) and tested all
three real shapes directly: progressive MP4 **1.23s**, HLS manifest **1.80s**, and — as a
sanity check that the harness itself would actually catch the original bug — audio-only DASH
**timed out at 30s**, reproducing the original failure. Both formats the selector can actually
resolve to are fast; the fix holds regardless of which one yt-dlp picks for a given video.

**Verified live end-to-end**: cleared `bgm-pool.json` to force a real fresh channel scan (matching
the original repro conditions), rebuilt the packaged `.app`, and had the user select "BGM" again —
confirmed playing quickly, no more stuck spinner.

**Not yet re-verified**: the rest of the BGM QC scenarios blocked by this bug (Next/Previous/
Reset/history/restore-on-relaunch/listen-count) — this fix only unblocks scenario 1. A fresh full
`/qc` pass over the `bgm` feature is still needed.
