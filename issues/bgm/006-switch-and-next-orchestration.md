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
