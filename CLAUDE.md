# Playlist Bar

Native macOS menu bar app that plays 4 fixed YouTube playlists as background audio via yt-dlp +
AVPlayer. Full requirements and decisions: [SPEC.md](SPEC.md). Backlog: [issues/](issues/) (see
`issues/INDEX.md` for status, `issues/FEATURES.md` for feature-level readiness — all 36 issues are
`done`; QC is in progress feature-by-feature, see "Status" below).

## Build & run

Day-to-day development: this is a Swift Package, not a hand-authored `.xcodeproj` — Xcode can
open `Package.swift` directly (File > Open) and build/run/debug it like a native project.

```bash
swift build
swift run
```

The app is a `MenuBarExtra`-only app (no Dock icon, via
`NSApp.setActivationPolicy(.accessory)` in `Sources/PlaylistBar/PlaylistBarApp.swift`) — look for
its icon in the menu bar after running, not a new window or Dock entry.

**Real `.app` bundle** (needed for Launch-at-Login/`SMAppService`, and eventually for
distribution — a bare `swift build` executable has no `Info.plist`/bundle identity, which
`SMAppService.register()` requires and throws `Invalid argument` without):

```bash
./Scripts/package-app.sh          # release build by default; pass "debug" to override
open dist/PlaylistBar.app
```

This assembles `dist/PlaylistBar.app/Contents/{MacOS,Resources}`, copies in
`Packaging/Info.plist` (bundle id `com.studiobleumoutarde.PlaylistBar`, `LSUIElement=true`), and
ad-hoc code-signs it. `swift build`/`swift run` are unaffected — only use this when you actually
need the bundled app (testing/using Launch-at-Login, or a real distributable build).

Requires `yt-dlp` on PATH — install with:

```bash
brew install yt-dlp
```

(Already installed on this machine at `/opt/homebrew/bin/yt-dlp`.) Note: `yt-dlp` lookups in this
codebase explicitly search `/opt/homebrew/bin`/`/usr/local/bin` in addition to inherited PATH —
GUI/login-item-launched apps don't get an interactive shell's PATH, so a bare PATH lookup would
miss a Homebrew install once this app isn't run via `swift run` from a terminal. See
`YtDlpAvailability.swift`.

Also requires `ffmpeg` on PATH (for per-track loudness normalization, `volume-control-003`) —
install with:

```bash
brew install ffmpeg
```

Installed on this development machine as of 2026-08-09 (at `/opt/homebrew/bin/ffmpeg`) — the real
subprocess call has since been exercised live and confirmed working (real measured gains, e.g.
`0.496`, `0.820` for actual playlist tracks; see `volume-control-007`'s "QC feedback" note, which
is also where a real timeout-handling bug was found and fixed once real analysis timing was
observable). Same PATH-hardening as `yt-dlp` above — see `FfmpegAvailability.swift`.

## Layout

- `Sources/PlaylistBar/PlaylistBarApp.swift` — app entry point. `MenuBarExtra` with a dynamic
  label (icon-only, see below) and `ContentView` as the dropdown content. Owns the single
  `PlaybackController` instance (shared between label and dropdown) and kicks off
  `restoreLastSession()` from the label's `.task` (the label, unlike the dropdown content, is
  instantiated immediately at launch — needed so the previous session is restored before the
  dropdown is ever opened). `AppDelegate` sets `.accessory` activation policy (no Dock icon).
  **Icon-only label** (changed 2026-08-12, via `/interview` — see SPEC.md's "UI (menu bar
  dropdown)" for the full writeup): the label originally paired an icon with the current track
  title as an explicit `HStack { Image(systemName:); Text(menuBarTitle) }` (not
  `Label(_:systemImage:)` — a `MenuBarExtra` status item doesn't reliably render `Label`'s title
  text next to its icon, collapses to icon-only; found via QC on 2026-08-09, see
  menu-bar-ui-004), with `menuBarTitle`'s truncation length halved from 40 to 20 characters on
  2026-08-11 after a user report that the untruncated title could cover the system menu bar's
  battery icon. That whole title-text label was then dropped entirely on 2026-08-12: the user
  found PlaylistBar's icon getting hidden by ordinary macOS menu-bar-overflow (too many status
  items for the available width — confirmed via `ps` the app process was still running, not
  crashed), and a variable-width text label was judged the likely reason this item specifically
  kept losing that contest. The label is now just `Image(systemName:)`, with the glyph swapping
  between `"music.note"` (playing) and `"pause.circle"` (paused) — `controller.isPlaying` — as a
  zero-width way to keep some status visible without opening the dropdown. A `.help()` hover
  tooltip carrying the track title was tried as a way to preserve some of the lost glance info,
  but confirmed live (twice) not to render at all on `MenuBarExtra` status items — same root cause
  as the `Label`-text-collapse quirk above (the label is hosted specially by AppKit and doesn't
  wire up SwiftUI's tooltip mechanism). Fixing that would mean replacing `MenuBarExtra` with a
  hand-rolled `NSStatusItem`; judged not worth it for a tooltip, so it was reverted rather than
  pursued — the track title is dropdown-only now.
- `Sources/PlaylistBar/ContentView.swift` — the dropdown: yt-dlp-missing / error messaging,
  playlist `Picker`, transport buttons (Previous/Play-Pause/Next/Reset), the previous-5/current/
  next-5 track list (click any row to jump to it), a Launch-at-Login `Toggle`, and Quit. All
  driven by an injected `@ObservedObject var controller: PlaybackController`. The track list's
  `ScrollView` needs an explicit `minHeight` (not just `maxHeight`) — inside `MenuBarExtra`'s
  auto-sizing window, a `ScrollView` with only a max height collapses its ideal height to ~0 even
  with real rows inside it; found via QC on 2026-08-09, see menu-bar-ui-003. The yt-dlp-unavailable
  banner and `controller.errorMessage` are rendered `if`/`else if`, not two independent `if`s — a
  missing yt-dlp is also what drives `errorMessage` into its own yt-dlp-not-found state, so showing
  both stacked was always a duplicate of the same condition, never two distinct problems; found via
  QC on 2026-08-09, see menu-bar-ui-005. Derives `isWaiting = controller.isLoading ||
  controller.isResolvingTrack || controller.isBuffering` (playlist-switch scan, fresh-track
  resolve, mid-stream stall — one signal for all three) and debounces it via `.task(id: isWaiting)`
  with a 300ms delay before actually showing a loading state, so a fast cache-hit switch or quick
  resolve never visibly flickers one in and out (dropping back to not-waiting happens immediately,
  no delay). While debounced-true, the Play/Pause button's icon becomes a small `ProgressView()`
  spinner, replacing (not stacking with) the play/pause icon — added for menu-bar-ui-006,
  2026-08-09; verified live (spinner shows on Next/Previous and playlist switch, no regression to
  normal steady-state play/pause). `isWaiting` also ORs in `controller.isAwaitingLoudnessAnalysis`
  (volume-control-008, 2026-08-09) — the existing debounce/spinner mechanism covers the
  loudness-analysis wait for free, no new UI code beyond that one extra condition. A
  `Slider(value:in:)` between the transport controls and the track list (volume-control-002,
  2026-08-09) is the master-trim control — bound to `controller.masterVolume` via a get/set
  `Binding` (same pattern as `playlistSelection`), no numeric readout, flanked by two speaker SF
  Symbols. **BGM picker entry** (`bgm-010`, 2026-08-10): the `Picker` gained a 5th row for
  `PlaybackController.bgmPlaylist` after the 4 fixed playlists; `playlistSelection`'s `set`
  branches on `newValue == PlaybackController.bgmPlaylist` to call `controller.switchToBGM()`
  instead of `switchTo(playlist:)`. **BGM track list** (`bgm-011`, 2026-08-10): the track-list
  `ScrollView` now branches on `controller.isBGMActive` — the BGM branch renders a new
  `displayedBGMHistory` computed property (`bgmHistory[max(0, current-5)...current]`, where
  `current = controller.bgmCurrentHistoryIndex` — up to 5 previous entries plus whichever one is
  current, never anything "after" it, since BGM has no next-track concept), each row showing the
  title (same accent/semibold highlight-if-current convention as the fixed-playlist list) plus the
  track's local listen count in trailing secondary text, tapping a row calls
  `controller.selectBGMHistoryEntry(at:)` (`bgm-007`). The non-BGM branch (`displayedTracks`) is
  unchanged. Known simplification: a row's shown listen count is a snapshot from when it was
  selected, not a live re-read of the pool, so the currently-playing track's count doesn't
  visibly tick up in real time as `bgm-005`'s threshold is crossed mid-play — still accurate,
  just not reactive for that one row.
- `Sources/PlaylistBar/PlaybackController.swift` — the central `ObservableObject` tying
  everything together: `switchTo(playlist:)`, `previous()`/`next()` (wrap-around), `reset()`,
  `selectTrack(at:)`, `togglePlayPause()`, `setMasterVolume(_:)`, and finish-triggered
  auto-advance, all funneling
  through one `play(startingAt:generation:)` helper that resolves via `TrackAvailabilityResolver`
  (auto-skips unavailable tracks) and persists position via `PlayerStateStore`. Publishes
  `isResolvingTrack`, true for the duration of that resolution — surfaced by `ContentView` for
  menu-bar-ui-006 — reset via the same `switchGeneration`-guarded pattern as every other state
  mutation there, so a superseded call can't clear a newer one's in-flight flag. A
  `switchGeneration` counter guards every state-mutating method against races from overlapping
  calls. `restoreLastSession()` is the one path that loads without auto-playing (startup-002). A
  `hasLoadedCurrentTrack` flag distinguishes "displaying a restored position" from "actually
  loaded into the player", so the first Play press after a restore correctly resolves and starts
  audio instead of silently no-op'ing. Publishes to `MPNowPlayingInfoCenter` reactively via
  `didSet` on its own state, and wires `MPRemoteCommandCenter` (media keys) in `init`. `play(
  startingAt:generation:)` sets `currentIndex` optimistically *before* resolving (not only on
  success) and no longer nils it back out on a resolution failure — otherwise the dropdown's track
  list (which reads off `currentIndex`/`tracks`) went completely blank on any resolution error even
  though `tracks` itself was still populated and correct; found via QC on 2026-08-09, see
  menu-bar-ui-005. Publishes `masterVolume` (0.0–1.0, the app-wide gain stage independent of
  system volume — see `AudioPlayer.swift` and `PlayerState.swift` below), initialized from
  `PlayerStateStore` and applied to `AudioPlayer.volume` in `init` before any playback path can
  run, so a relaunch never briefly plays at full volume before correcting. `setMasterVolume(_:)`
  clamps, applies immediately (no restart/reload — `AVPlayer.volume` is a player-level property,
  not per-item), and persists. Added for `volume-control-001`, 2026-08-09; this is the master
  trim, one of two gain stages alongside per-track loudness normalization — see SPEC.md's "Volume
  & loudness normalization". `currentTrackGain`/`applyEffectiveVolume()` (volume-control-005)
  combine `masterVolume` with the current track's cached `normalizationGain` (see
  `PlaylistCache.swift` below), applied right before `player.load` at both places a track actually
  starts (`play(startingAt:generation:)`'s success case, `advanceOnFinish`'s preloaded fast path)
  — deliberately *not* reapplied reactively when a gain is measured mid-play, so a track already
  playing unnormalized can't jump volume partway through; it's corrected next time it plays. Owns
  a `loudnessCoordinator: LoudnessGainCoordinator` (see its own entry below); wires
  `onGainMeasured` in `init` to update `tracks` in-memory. Publishes `isAwaitingLoudnessAnalysis`
  (volume-control-007/008) — true while `play(startingAt:generation:)` is waiting (bounded 5s,
  `Self.loudnessAnalysisTimeout`) on analysis for a track with no cached gain yet, covering both
  out-of-order jumps and the auto-advance-fallback case (since `advanceOnFinish`'s no-preload-ready
  branch also funnels through `play()`). Reset at the same optimistic entry point that already
  sets `currentIndex`/`isResolvingTrack`, and only cleared post-wait *after* the
  `switchGeneration` guard — reversed from an initial version that cleared it before the guard,
  which let a stale/superseded call clobber a newer call's genuinely-still-waiting state.
  **BGM integration** (`bgm-006`, 2026-08-10): `switchToBGM()`, `advanceBGM(generation:)`, and
  `playBGM(startingFrom:generation:)` add BGM support without a parallel state model — BGM's
  "current track" is represented via the *same* `tracks`/`currentIndex` this file already uses (a
  single-element `tracks` array, `currentIndex = 0`, `currentPlaylist` set to a synthetic
  `Playlist(slug: "bgm", name: "BGM", url: "")`), which is what makes Now Playing info, the menu
  bar title, and `applyEffectiveVolume()`/`currentTrackGain` all work for BGM with zero changes to
  any of them. `isBGMActive` is computed from `currentPlaylist?.slug`, never a separate flag.
  `next()`/`advanceOnFinish()` branch to `advanceBGM` (which excludes the current track via
  `BGMSelector` — see `BGMSelector.swift` above); `previous()`/`reset()` are guarded no-ops while
  BGM is active for now (`bgm-007`/`bgm-008` will replace these — letting the old index-based
  logic run against BGM's one-element `tracks` array would silently bypass `BGMCacheStore`'s
  listen-count persistence, `bgmHistory`, and `bgmListenTracker`). `playBGM` has its own bounded
  retry-on-unavailable loop (mirroring `TrackAvailabilityResolver`). No BGM-specific next-track
  preloader exists yet — BGM's next pick isn't decided until needed, so auto-advance has a real
  (usually brief) resolution gap unlike the fixed playlists' gapless transition; a disclosed gap,
  not silently absorbed. See `bgm-006`'s own Notes for the full list of scope decisions made here.
  **Startup-latency fix (2026-08-10)**: `playBGM` originally had its own bounded loudness-analysis
  wait, `measureBGMGain(url:timeout:)` (a standalone continuation-race, deliberately not
  `LoudnessGainCoordinator`, which is hardcoded to persist via `PlaylistCacheStore` and would've
  silently discarded every BGM measurement). QC found that selecting BGM could get stuck on a
  loading spinner for *minutes* despite that 5s bound working correctly — root cause was `AVPlayer`
  itself being slow to become ready-to-play for BGM's long (15 min–1 hr+), `moov`-atom-at-end
  audio-only streams, unrelated to anything in this file. Fix: `playBGM` now resolves via
  `StreamResolver.resolve(videoID:preferProgressive: true)` (a faststart format instead — see
  `StreamResolver.swift` above) and no longer measures loudness for BGM at all — the whole
  `measureBGMGain` call and function were deleted; BGM tracks always construct with
  `normalizationGain: nil`, which `currentTrackGain` already treats as `1.0`. Full investigation
  and decisions in `issues/bgm/006-switch-and-next-orchestration.md`'s "QC feedback" and "Fix"
  notes, and SPEC.md's "BGM channel playback" — "Startup latency for long videos". **Real
  Previous/history**
  (`bgm-007`, 2026-08-10) replaced the guarded no-op: `bgmHistoryPosition: Int?` (`nil` = live
  edge) drives `previousBGM()`/`selectBGMHistoryEntry(at:)`, both replaying via `playBGM`'s new
  `appendToHistory: Bool` parameter (`false` for a history replay, since the track's already in
  `bgmHistory`). `advanceBGM` (Next/auto-advance) truncates any "forward" history and resets the
  position before making its next fresh pick, per SPEC's discard-not-redo rule. **`reset()`'s BGM
  branch** (`bgm-008`, 2026-08-10) replaced an earlier guarded no-op: calls the new
  `AudioPlayer.restart()`, sets `isPlaying = true`, no `switchGeneration` bump (nothing async is
  resolving) and no history/persistence change — it's the same track, just seeked back to 0:00.
  **`restoreBGMSession()`** (`bgm-009`, 2026-08-10), called from `restoreLastSession()` when the
  saved slug is `"bgm"`: loads the pool and displays the persisted last-played video (or a fresh
  `BGMSelector` pick) via `tracks`/`currentIndex`, seeding `bgmHistory` with it — but never calls
  `player.load`/sets `isPlaying`, matching the fixed playlists' restore-without-autoplay contract.
  This also closed a gap `bgm-006` had flagged: `togglePlayPause()`'s fallback branch (for
  `currentIndex` set but `hasLoadedCurrentTrack` false — the exact state a BGM restore produces,
  and the only way that state becomes reachable for BGM) now branches on `isBGMActive` to route
  through `playBGM(...,appendToHistory: false)` instead of the fixed-playlist `play(startingAt:)`,
  which would have silently fed a BGM track through `LoudnessGainCoordinator`/`NextTrackPreloader`
  and discarded its gain measurement (see `bgm-006`'s Notes on why those can't be reused for BGM).
  **`Self.bgmPlaylist`** (`bgm-010`, 2026-08-10): a single shared static `Playlist` constant for
  BGM's synthetic playlist value, replacing two independently-constructed literals in
  `switchToBGM()`/`restoreBGMSession()` — `Playlist`'s equality is field-based, so the picker's
  selection-tag comparison in `ContentView.swift` needed one definitively-shared value, not two
  literals that merely happened to match. **`bgmCurrentHistoryIndex: Int?`** (`bgm-011`,
  2026-08-10): `bgmHistoryPosition` if set, else the live edge (`bgmHistory.count - 1`) — exposed
  so `ContentView.swift`'s BGM track list doesn't need to know about the private
  `bgmHistoryPosition` implementation detail. **`switchToBGM()` history-duplication fix** (found
  during a fresh `bgm` QC pass, fixed 2026-08-10): switching away from BGM to a fixed playlist and
  back used to append a duplicate entry to `bgmHistory` for the resumed track, because
  `switchToBGM()` unconditionally passed `appendToHistory: true` even when the resumed video was
  already the most recent (or a mid-history) entry — every other "resume a known track" path
  (`previousBGM()`, `selectBGMHistoryEntry(at:)`) already avoided this by passing `false`.
  `switchToBGM()` now searches `bgmHistory` for the resumed video first; if found, it resumes in
  place (sets `bgmHistoryPosition` to that entry's index, `appendToHistory: false`) instead of
  appending — only a genuinely fresh pick (nothing saved yet, or the saved video fell out of the
  pool) still appends. See `bgm-006`'s "Fix (2026-08-10, second pass)" note for the full
  before/after and verification (a standalone script covering the live-edge and mid-history resume
  cases, plus a live repeated switch-away/switch-back check with the packaged app).
  **Per-track seek-position save/resume for the 4 fixed playlists** (`playback-controller-006`,
  2026-08-11, part of the per-track seek-position-resume backlog — see SPEC.md's "Local state (per
  playlist)"): a `PlaybackController`-lifetime periodic `Timer` (5s interval, same pattern as
  `BGMListenTracker`'s timer) plus a shared `savePosition()` helper — called on pause, and at the
  top of `switchTo(playlist:)`/`switchToBGM()` (before any state mutation, so it captures the
  *outgoing* playlist's live position) — persist the current position via
  `PlayerStateStore.setLastPlayedPosition` (`player-state-003`). `play(startingAt:generation:
  resumePosition:)` gained the `resumePosition` parameter (default `false`): `true` only from
  `switchTo(playlist:)` and `togglePlayPause()`'s post-restore fallback (the cold-start-relaunch
  case) — every other caller (`step`/`reset`/`selectTrack`/`advanceOnFinish`'s fallback) keeps
  `false`, so Previous/Next/Reset/track-click/auto-advance still start at 0:00 per SPEC.md's
  "Behavior rules". When honored, the saved position is only actually applied if
  `PlayerStateStore.lastPlayedTrack(forPlaylistSlug:)` still matches the track
  `TrackAvailabilityResolver` actually resolved to — guards against inheriting a stale position
  when an unavailable-track auto-skip lands on a different video than the one the position was
  saved for. `AudioPlayer.nearEndClampSeconds` (see below) was widened from `private` to internal
  so this file can predict the same near-end clamp `AudioPlayer.load` applies internally, and
  persist `0` (not the pre-clamp `startTime`) for a clamped resume — found and fixed during this
  issue's own self-review; without it, a clamped resume would briefly persist a wrong position
  until the next periodic save corrected it. Verified via a standalone script covering the two
  pure decision points (resume-honored-on-match / ignored-on-mismatch / ignored-when-not-
  requested, and clamp-vs-no-clamp persistence) plus `swift build`/a clean `swift run` launch —
  **not yet live-verified** (actually switching playlists and confirming audible resume), deferred
  to a future `/qc` pass per this project's established human-driven verification pattern for
  GUI-observable behavior.
  **BGM's own save/resume wiring** (`bgm-012`, 2026-08-11): `savePosition()` (above) turned out to
  already be playlist-agnostic — it only ever read `currentPlaylist?.slug`/`hasLoadedCurrentTrack`,
  both shared by BGM's synthetic playlist representation — so extending the periodic timer/on-
  pause/on-switch-away saves to BGM was a one-line fix (dropping `savePosition()`'s `!isBGMActive`
  guard) rather than a second near-duplicate save path. `playBGM(startingFrom:generation:
  appendToHistory:resumePosition:)` gained the `resumePosition` parameter, mirroring
  `play(startingAt:generation:resumePosition:)` exactly (same stale-position video-id guard, same
  near-end-clamp persistence prediction) — passed `true` from both of `switchToBGM()`'s call sites
  and `togglePlayPause()`'s post-restore BGM fallback; `advanceBGM`/`previousBGM`/
  `selectBGMHistoryEntry` keep the default `false`. Does not touch BGM's dropped per-track loudness
  normalization. See `BGMListenTracker.swift`'s entry above for `bgm-013`, implemented alongside
  this (per this issue's own Notes) to fix the listen-count-threshold interaction resuming
  introduces.
- `Sources/PlaylistBar/Playlists.swift` — `Playlist` model and `FixedPlaylists.all`, the app's 4
  fixed playlists (slug/name/URL) transcribed from SPEC.md.
- `Sources/PlaylistBar/PlaylistLoader.swift` — `PlaylistLoader`, cache-first playlist loading:
  instant from cache when present, background refresh when stale (>24h), full scan only when no
  cache exists at all. Exposes `lastScanErrorMessage` for menu-bar-ui-005.
- `Sources/PlaylistBar/PlaylistScanner.swift` — `PlaylistScanner.scan(playlistURL:)`, a full
  `yt-dlp --flat-playlist` scan into an ordered `[CachedTrack]`. Verified against the real Rock3
  playlist (2,448 tracks, ~19s, no deadlock).
- `Sources/PlaylistBar/PlaylistCache.swift` — `CachedTrack`/`PlaylistCache` models and
  `PlaylistCacheStore` (load/save JSON per playlist, keyed by slug) under
  `~/Library/Application Support/PlaylistBar/`. `PlaylistCache.isStale` implements the 24h
  refresh threshold from SPEC.md. `CachedTrack.normalizationGain: Double?` (added for
  volume-control-004, 2026-08-09) is the cached per-track loudness gain, `nil` until analyzed —
  must be `var`, not `let`: a `let` stored property with an initial value is a compiler-flagged
  non-decodable constant in Swift, so it would've silently always decoded as `nil` regardless of
  what was actually on disk (caught via the compiler's own warning, not by inspection).
  `PlaylistCacheStore.setNormalizationGain(_:forVideoID:playlistSlug:)` updates one track in place
  without a full re-scan. Backward-compatible: a cache file written before this field existed
  decodes it as `nil` automatically (verified via a standalone script).
- `Sources/PlaylistBar/BGMCache.swift` — `BGMTrack`/`BGMPoolCache`/`BGMCacheStore` (`bgm-001`,
  2026-08-10), the BGM feature's equivalent of `PlaylistCache.swift` above, persisted separately
  as `bgm-pool.json` under the same Application Support directory. `BGMTrack` has a `listenCount`
  (local-only play count, drives BGM's fewest-listens selection — see SPEC.md's "BGM channel
  playback"). Deliberately carries no per-track "which channel" field — SPEC.md's BGM pool is one
  shared selection space across every configured channel (currently one), not one entry per
  channel, so channel origin isn't needed here. `BGMCacheStore.merge(freshlyScanned:into:)` is
  the key divergence from `PlaylistCacheStore`: a 24h rescan (`bgm-003`) must preserve each
  still-eligible video's `listenCount` by video id rather than replacing the whole track list the
  way `PlaylistLoader`'s rescan does — a full replace would silently reset every video's listen
  count every 24 hours, defeating the feature. Same copy-mutate-reconstruct-save pattern as
  `PlaylistCacheStore.setNormalizationGain` (immutable `let` struct fields, not mutated in place)
  — an early draft used `var` fields and in-place mutation instead; caught and fixed during this
  issue's own self-review for consistency with the established convention. **`normalizationGain`
  removed (2026-08-10 fix)**: `BGMTrack` originally mirrored `CachedTrack.normalizationGain`
  (with a matching `BGMCacheStore.setNormalizationGain`), but BGM no longer measures loudness at
  all — see `PlaybackController.swift`'s `playBGM` entry below for why — so both were deleted as
  permanently dead rather than left around always `nil`. Backward-compatible: `Codable` synthesis
  ignores unknown JSON keys, so an existing `bgm-pool.json` with old `normalizationGain` entries
  still decodes fine.
- `Sources/PlaylistBar/BGMChannelScanner.swift` — `BGMChannelScanner.scan(channelURL:)`
  (`bgm-002`, 2026-08-10), a channel-scanning sibling to `PlaylistScanner.scan(playlistURL:)`:
  scans a channel's `/videos` tab (appends `/videos` to the given URL if not already present) via
  the same `yt-dlp --flat-playlist -J` + `YtDlpRunner` mechanism, but additionally decodes and
  filters on `duration`/`availability` (which a plain playlist scan doesn't need) — confirmed live
  that yt-dlp's flat-playlist output already reports both fields per entry for a channel's videos
  tab, so no extra per-video resolution calls are needed. Eligibility: `duration >= 900` (15 min)
  and `availability != "subscriber_only"` (members-only marker). Returns fresh `BGMTrack`s (see
  `BGMCache.swift` above) with `listenCount` at its default — merging against the existing pool to
  preserve it is `bgm-003`'s job, not this scan.
- `Sources/PlaylistBar/BGMChannels.swift` — `BGMChannels.all: [String]` (`bgm-003`, 2026-08-10),
  the configured BGM channel URL list (currently one), mirroring `FixedPlaylists.all`'s hardcoded
  convention — no in-app UI to edit it.
- `Sources/PlaylistBar/BGMLoader.swift` — `BGMLoader` (`bgm-003`, 2026-08-10), a structural mirror
  of `PlaylistLoader`: cache-first via `BGMCacheStore`, background refresh only when stale (same
  24h threshold). The refresh scans every `BGMChannels.all` entry, pools+dedupes across channels
  by video id, and — the key divergence from `PlaylistLoader` — merges the result against the
  existing on-disk pool via `BGMCacheStore.merge` rather than replacing it, so listen counts
  survive a rescan. A failed scan leaves the existing pool untouched, same "don't let a broken
  refresh take away a working cache" rule as `PlaylistLoader`.
- `Sources/PlaylistBar/BGMSelector.swift` — `BGMSelector.selectNext(from:excluding:)` (`bgm-004`,
  2026-08-10), the pure fewest-listens/random-tiebreak selection function: filters out the
  excluded (just-played) video unless that would empty the pool, finds the minimum `listenCount`
  among what's left, and returns a uniformly-random pick among whichever videos are tied at that
  minimum. `nil` only for a genuinely empty pool. No I/O, no persistence — mirrors this codebase's
  existing convention of isolating selection logic (see `TrackAvailabilityResolver`) as directly
  testable pure functions.
- `Sources/PlaylistBar/BGMListenTracker.swift` — `BGMListenTracker` (`bgm-005`, 2026-08-10):
  `start(videoID:duration:startPosition:currentTime:)` arms a 1Hz `Timer` (same pattern as
  `AudioPlayer`'s own end-of-track watchdog — `Timer` + `RunLoop.main.add(_:forMode:)` + a
  `Task { @MainActor in }` hop, since a `Timer` callback isn't itself actor-isolated) that, once
  elapsed playback crosses `min(30, duration * 0.2)`, calls
  `BGMCacheStore.incrementListenCount(forVideoID:)` exactly once and stops. `cancel()` stops
  without incrementing; `start()` always cancels any prior in-flight tracking first. **Wiring
  requirement for whatever calls this** (`bgm-006`): switching away from BGM to a fixed playlist
  must explicitly call `cancel()` — `start()`'s auto-cancel only covers switching *between* BGM
  videos, so a still-armed tracker left running after leaving BGM would keep polling
  `AudioPlayer.currentTime` against whatever's now loaded and could misattribute a listen to a
  video that's no longer playing. **`startPosition` parameter** (`bgm-013`, 2026-08-11, part of
  the 2026-08-11 resume backlog — see SPEC.md): the threshold is now measured against `currentTime
  () - startPosition` (elapsed *since this `start()` call*), not `currentTime()`'s absolute value
  — otherwise a video resumed already past the absolute threshold (e.g. 25:00 of a 30:00 video,
  `bgm-012`) would credit a listen almost instantly. Defaults to `0` (every from-the-beginning call
  unaffected). **Deliberately not** captured by calling `currentTime()` inside `start()` itself, as
  this issue's own originating Notes suggested — `PlaybackController.playBGM` calls `start()`
  synchronously right after `player.load(...)`, but `AVPlayer.seek(to:)` (which `load` uses to
  honor a resume `startTime`) is asynchronous, so `currentTime()` generally still reads stale/zero
  at that exact point; found while implementing this issue, before it ever shipped. Fixed by having
  the caller pass its already-known, already-clamp-adjusted effective start time in explicitly
  instead of trying to read it back from player state that hasn't caught up yet — see the
  `PlaybackController.swift` entry above.
- `Sources/PlaylistBar/StreamResolver.swift` — `StreamResolver.resolve(videoID:preferProgressive:)`,
  resolves a playable stream URL via yt-dlp for one video, distinguishing genuinely unavailable
  videos (best-effort message matching) from other failures. Default (`preferProgressive: false`,
  used by the 4 fixed playlists via `PlaybackController`/`NextTrackPreloader`/
  `TrackAvailabilityResolver`) prefers M4A/AAC (`bestaudio[ext=m4a]/bestaudio`) over yt-dlp's
  default best-bitrate pick (usually WebM/Opus), since AVFoundation doesn't natively decode WebM —
  AVPlayerItem would silently never become ready otherwise. Also returns the video's real duration
  via yt-dlp's own metadata (`--print "%(duration)s"` piggybacked onto the same `-g` call, no extra
  process) — see `AudioPlayer.swift` below for why. **`preferProgressive: true`** (added 2026-08-10
  for BGM's startup-latency fix — see `PlaybackController.swift`'s `playBGM` entry below and
  SPEC.md's "BGM channel playback" — "Startup latency for long videos") instead resolves via
  `best[acodec!=none][vcodec!=none]`, yt-dlp's legacy progressive (audio+video combined,
  faststart) format selector — used by BGM only. **`resolveTimeout`** (`playback-engine-007`,
  2026-08-13, see SPEC.md's "Resolution and buffering timeouts"): `resolve` now passes a 10s
  timeout down to `YtDlpRunner.run`, fixing a real bug found live — this call previously had no
  bound at all, so a stalled `yt-dlp -g` could leave a caller (any of `TrackAvailabilityResolver`/
  `NextTrackPreloader`/`PlaybackController.playBGM`) awaiting it forever, stranding the UI on a
  permanent loading spinner. A timeout throws `ResolutionError.timedOut`, which every existing
  caller already treats the same as any other non-`ytDlpNotFound` failure (skip like an
  unavailable track) — no call-site changes needed for the new case itself.
  **Real incident, 2026-09-02** (found via `/interview`): selecting a track in Rock3 triggered
  `TrackAvailabilityResolver`'s internal auto-skip loop through ~60 consecutive tracks in one
  click (that loop retries silently with no UI update per attempt — see its own doc comment) and
  even the track it finally landed on stayed stuck on the loading spinner. Root cause: `yt-dlp`
  was 6 weeks out of date on this machine (2026.07.04 vs. Homebrew stable 2026.08.19) — YouTube
  periodically breaks older yt-dlp versions. Fixed by `brew upgrade yt-dlp`; re-verified live
  (all previously-failing tracks, including the one it got stuck on, now resolve in 1-3s; no app
  restart needed since `YtDlpRunner` resolves the yt-dlp binary path fresh per call, never
  cached). Caveat: the very first track tested had actually resolved fine even on the old
  version in isolation, so this may have compounded a YouTube-side rate-limit/burst event rather
  than the old version being uniformly broken — user confirmed this was a first-time occurrence,
  so it's being treated as resolved rather than chased further. **Real gap found and fixed
  alongside this**: every resolution failure that isn't a recognized "video genuinely gone" case
  was being swallowed into a generic UI message (`PlaybackController`'s `"Couldn't play this
  track — check your network connection."`) with no record anywhere of the real yt-dlp error —
  there was no way to tell an outdated-yt-dlp failure apart from rate-limiting apart from a
  genuinely broken extractor. Fixed by logging the actual failure (exit code + stderr for a
  process failure, or the timeout itself) via `os.log` right where each error originates in
  `resolve` — viewable via Console.app or `log show --predicate 'subsystem ==
  "com.studiobleumoutarde.PlaylistBar"'` — chosen over a custom log file since this app has no
  existing logging infrastructure to extend. A stagger/backoff between the auto-skip loop's rapid
  consecutive attempts was considered (rapid-fire calls could themselves provoke rate-limiting)
  but deliberately not added — user judged it unnecessary for what's currently a one-off.
- `Sources/PlaylistBar/AudioPlayer.swift` — `AudioPlayer`, wraps a single `AVPlayer`: load/play/
  pause/stop plus an `onFinish` callback for natural track completion. Exposes `volume` (0.0–1.0)
  as a thin pass-through to `AVPlayer.volume` itself — a player-level property, so it applies
  immediately to whatever's loaded and survives `replaceCurrentItem` (track changes) with no
  reload; added for `volume-control-001`, 2026-08-09. Holds a
  `ProcessInfo.beginActivity`/`endActivity` background-activity token for as long as it's actively
  playing (acquired in `play()`, released on pause/stop/finish/`deinit`) — this is an `LSUIElement`
  menu bar app with no visible window at any point, a prime App Nap target once backgrounded;
  real hardening, added during `playback-engine` QC on 2026-08-09, though it turned out not to be
  the actual cause of that session's bug (see below). Also exposes `isBuffering`, driven off
  `AVPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate` (relaying AVFoundation's own
  playing-vs-waiting signal rather than reinventing stall detection), mirrored onto
  `PlaybackController.isBuffering` via a `setOnBufferingChange` closure callback (same convention
  as `setOnFinish` — this codebase doesn't use Combine `.sink`/`AnyCancellable` anywhere). Ready
  for `menu-bar-ui-006` to display; not itself what fixes the bug below. Also exposes `currentTime:
  Double` (`bgm-005`, 2026-08-10), a thin `CMTimeGetSeconds(player.currentTime())` pass-through —
  added so `BGMListenTracker` can observe playback progress without `AudioPlayer` needing to know
  why, reusing the same underlying `AVPlayer` state as the end-of-track watchdog below rather than
  a second competing notion of position. `restart()` (`bgm-008`, 2026-08-10) —
  `player.seek(to: .zero)` + the existing `play()`, resetting `hasFiredFinishForCurrentItem` too —
  used by BGM's Reset, which restarts the *current* item rather than resolving a new one. Verified
  live against a real resolved stream: seeks genuinely back near 0 (not just continuing forward)
  and resumes advancing afterward with `rate == 1.0`. **`load`'s `startTime` parameter**
  (`playback-engine-006`, 2026-08-11): `load(url:duration:startTime:autoplay:)` seeks the freshly-
  replaced item to `startTime` right after `replaceCurrentItem`, same mechanism as `restart()`
  above, just non-zero. Defaults to `nil` (unchanged 0:00-start behavior — every existing call site
  is unaffected). Includes a near-end clamp: a `startTime` within 5s of the trusted `duration`
  falls back to 0:00 instead of playing a couple seconds before the existing end-of-track watchdog
  fires an almost-immediate auto-advance. Mechanics only — this issue doesn't decide *whether* a
  saved position should be passed for a given track; that's `playback-controller-006` (fixed
  playlists, done 2026-08-11 — see the `PlaybackController.swift` entry above, which is also why
  `nearEndClampSeconds` is internal rather than `private`) and `bgm-012` (BGM), the latter not yet
  implemented as of this note. `itemTracksObserver` (added 2026-08-10 as
  part of BGM's startup-latency fix, see below) is a KVO observation on the current item's
  `tracks` — populated asynchronously as the asset loads, same as `timeControlStatusObserver`'s
  pattern — that disables (`isEnabled = false`) any `.video` track once known. Needed because
  BGM's fix (below) makes `StreamResolver` resolve a combined audio+video stream for BGM, and this
  `MenuBarExtra`-only app has no video surface anywhere to show it on — without this, `AVPlayer`
  would decode video frames for nothing for up to an hour per BGM track. No-op for the 4 fixed
  playlists' audio-only items. Invalidated at the top of `load()` (a fresh item each call) and in
  `stop()`; relies on `NSKeyValueObservation`'s automatic invalidate-on-dealloc for `deinit`, same
  as `timeControlStatusObserver` (which also has no explicit `deinit` line).
  **The real bug, found while implementing playback-engine-005 (2026-08-09):** YouTube serves
  resolved audio as a progressively-streamed, "not optimized" (moov-atom-at-end) M4A, so
  `AVFoundation` estimates duration before it can read the real one — reproducibly **~2x too
  long** (confirmed via `afinfo` on a fully-downloaded real stream: genuinely 142.31s vs
  `AVFoundation`'s own reported 284.68s for the same URL; `Content-Length` itself is correct,
  ruling out a network/throttling explanation — most likely a channel-count/bitrate
  misdetection). `AVURLAssetPreferPreciseDurationAndTimingKey` does not fix it. Real audio plays
  correctly then goes genuinely silent once true content ends, while `AVPlayer` keeps reporting
  `rate == 1` and `currentTime` advancing at real-time pace regardless — its own model never
  considers itself stalled, so `isBuffering` above can't catch this either. Fix: `load(url:
  duration:autoplay:)` takes the *trusted* duration from `StreamResolver`'s yt-dlp metadata and
  arms a plain wall-clock `Timer` watchdog (independent of `AVPlayer`'s own broken duration) that
  fires `onFinish` once real elapsed playback time reaches `duration + 2s` grace, guarded against
  double-firing alongside the canonical `AVPlayerItemDidPlayToEndTime` notification. Verified:
  `onFinish` now fires at 145.0s instead of 284.7s for the real previously-broken track: see
  playback-engine-005's "Fix" note for the full investigation and verification.
- `Sources/PlaylistBar/NextTrackPreloader.swift` — resolves the next track's stream URL (and its
  known real duration, see above) in the background while the current one plays, so auto-advance
  has no perceptible delay. `beginPreload` also takes a `playlistSlug` and a
  `LoudnessGainCoordinator` (volume-control-006, 2026-08-09) and calls its
  `beginAnalysisIfNeeded(track:url:playlistSlug:)` right after resolving the stream — fire-and-
  forget, so the preload itself never waits on it; normal forward listening gets its
  normalization gain ready with no added delay, same guarantee as the stream-URL preload itself.
- `Sources/PlaylistBar/LoudnessAnalyzer.swift` — `LoudnessAnalyzer.measureGain(url:)`
  (volume-control-003, 2026-08-09): runs
  `ffmpeg -hide_banner -nostats -i <url> -af loudnorm=print_format=json -f null -` via `Process`
  with an argument array (no shell — the resolved stream URL's query string can't be
  misinterpreted as shell syntax even though it isn't attacker-controlled here), draining stdout/
  stderr concurrently like `YtDlpRunner` to avoid the same pipe-buffer deadlock risk. `loudnorm`'s
  JSON loudness report is printed to stderr (ffmpeg's convention for filter/progress output, not
  stdout), located by its last `{...}` brace pair rather than a fixed line position. Converts the
  measured integrated loudness into a **cut-only** gain toward `targetLUFS = -14.0` (matches
  Spotify/YouTube Music's own normalization target) — `min(1.0, 10^((-14 - measured)/20))`,
  clamped so a track is never boosted above its original loudness (`AVPlayer.volume` is a
  0.0–1.0 attenuator only) and never NaN/non-finite on silence. JSON-parsing and gain-formula
  logic verified via a standalone script against a realistic `loudnorm` stderr sample; the actual
  subprocess call itself hasn't been exercised live yet — see "Build & run" above.
- `Sources/PlaylistBar/FfmpegAvailability.swift` — `FfmpegLocator.checkAvailability()`, a direct
  mirror of `YtDlpAvailability.swift` for `ffmpeg` (volume-control-003, 2026-08-09) — same PATH +
  Homebrew-dirs search rationale.
- `Sources/PlaylistBar/LoudnessGainCoordinator.swift` — coordinates measuring/caching/looking up
  per-track normalization gain (volume-control-006/007, 2026-08-09), shared by
  `NextTrackPreloader`'s opportunistic preload and `PlaybackController`'s out-of-order-jump
  bounded wait — the two are meant to share one fallback path per SPEC.md, which only actually
  holds if a caller giving up on a wait never cancels the analysis itself (otherwise an unlucky
  short current track would permanently lose that track's analysis instead of just missing it
  once). At most one in-flight `Task` per video id; `gain(for:url:playlistSlug:timeout:)` races
  that task against a timeout — whichever finishes first wins, and the loser keeps running to
  completion independently in the background, still reporting via `onGainMeasured` even after a
  caller has timed out. A timeout/failure fallback (`1.0`) is never written back to the cache —
  only a real measurement is.
  **Real bug found live during `playback-engine` QC (2026-08-09, see `volume-control-007`'s "QC
  feedback" note for the full writeup):** the original implementation raced via `withTaskGroup`,
  which structurally waits for *every* child task to finish before returning — including the
  "loser" branch, since cancelling a task group's wrapping child doesn't cancel an externally-
  stored `Task` it merely `await`s (`await task.value` doesn't observe that cancellation). This
  made the timeout illusory: the call didn't actually *return* until the real `ffmpeg` analysis
  finished, however long that took (confirmed taking 3–6+ seconds per track live on this
  machine) — indistinguishable from a frozen app. The original standalone-script verification for
  this race only checked the *returned value* was correct, never the *wall-clock latency*, which
  is exactly where the bug hid. **Fixed** by racing via `withCheckedContinuation` instead — two
  independent, unstructured `Task`s (inheriting this class's `@MainActor` isolation, so the
  shared "already resumed" guard needs no separate lock) each resume the continuation if they're
  first, and the function returns as soon as *either* resolves, with the loser still running
  independently afterward. Re-verified via a corrected standalone script (now checking timing,
  not just the value) and live in the app with real analysis passes.
- `Sources/PlaylistBar/TrackAvailabilityResolver.swift` — finds the next actually-playable track
  from a starting index (and its known real duration), auto-skipping unavailable ones with
  wrap-around, bounded to at most one full pass over the playlist so it can never hang even if
  every track is unavailable.
- `Sources/PlaylistBar/PlayerState.swift` — `PlayerStateStore`, persists last-played-track per
  playlist, the last active playlist, and the app-wide `masterVolume` (default `1.0`, "no
  attenuation" — added for `volume-control-001`, 2026-08-09) as `player-state.json`.
  **`lastPlayedPositionByPlaylist`** (`player-state-003`, 2026-08-11): one saved seek position
  (seconds) per playlist slug, tied to whichever track is currently that slug's last-played one —
  `lastPlayedPosition(forPlaylistSlug:)`/`setLastPlayedPosition(_:forPlaylistSlug:)`, mirroring
  the existing track-id pair. Storage only — write cadence and applying the saved position on load
  are `playback-controller-006` (fixed playlists, done 2026-08-11 — see the
  `PlaybackController.swift` entry above)/`bgm-012` (BGM, not yet implemented as of this note).
  **Real bug found and fixed while implementing this**: `State`'s synthesized `Decodable` didn't
  actually apply a
  property's `= default` for a missing key on any non-`Optional` field — only `Optional`
  properties get that treatment automatically. This was already a latent gap for `masterVolume`
  (any `player-state.json` from before volume-control-001 would fail to decode `State` at all,
  and `load()`'s catch-all would silently reset *every* field, not just default the missing one),
  confirmed via a standalone script. Fixed with a custom `init(from:)` using
  `decodeIfPresent(...) ?? <default>` for every field in `State`, covering both the new field and
  retroactively fixing `masterVolume`'s pre-existing gap — re-verified via a standalone script
  covering round-trip, a "recent-old" file (has `masterVolume`, lacks the new field), a "very-old"
  file (lacks `masterVolume` too), and a fully empty `{}`.
- `Sources/PlaylistBar/YtDlpAvailability.swift` — `YtDlpLocator.checkAvailability()`, a PATH
  (+ Homebrew dirs) check for `yt-dlp`.
- `Sources/PlaylistBar/YtDlpRunner.swift` — shared subprocess execution for yt-dlp: resolves its
  absolute path via `YtDlpLocator` (not bare-name PATH lookup) and runs it with an argument array,
  draining stdout/stderr concurrently to avoid a pipe-buffer deadlock on large output. **`run(
  arguments:timeout:)`** (`playback-engine-007`, 2026-08-13): an optional `Duration` timeout,
  `nil` by default so `PlaylistScanner`/`BGMChannelScanner`'s existing calls (a full playlist/
  channel scan legitimately takes longer than any single-video call) are unaffected. When set, the
  pipe-draining `DispatchGroup.wait` is given a deadline; on timeout the subprocess is
  `terminate()`d (not left running in the background — a stream-resolve stall reads as more likely
  a genuine hang than a merely-slow analysis, unlike the loudness-analysis timeout elsewhere in
  this codebase, which deliberately does let its loser keep running), then waited on again
  (now-fast, since termination closes the pipes) before throwing `RunError.timedOut`.
- `Sources/PlaylistBar/LoginItemManager.swift` — wraps `SMAppService.mainApp` register/unregister/
  status for the Launch-at-Login toggle. Only works against the real packaged `.app` (see
  `Scripts/package-app.sh` above) — throws against a bare `swift build` executable.
- `Packaging/Info.plist`, `Scripts/package-app.sh` — see "Build & run" above.
- `Sources/QCHarness/` — automated QC harness (added 2026-08-13, see SPEC.md's "Automated QC
  harness" for the full writeup). A second executable target driving the packaged `.app` from the
  outside via the Accessibility (AXUIElement) API — not XCUITest, since this is a Swift Package
  with no UI-test-bundle target type. `AX.swift` wraps the raw AXUIElement C API (attribute
  read/write, tree search — depth-first, order-preserving; an earlier `popLast()`-stack version
  silently reversed sibling order and produced a confusing false failure, see its own doc comment)
  plus real synthetic mouse/keyboard input (`Input.click`/`dismissAnyOpenMenu`) — used over
  `kAXPressAction` for buttons after finding live that AXPress on this app's SwiftUI controls is
  occasionally a no-op that still reports success. `PopoverController.swift` is the high-level API
  (find the status item via the per-app `AXExtrasMenuBar` attribute, open/close the popover —
  located via `CGWindowListCopyWindowInfo` by owning pid since it never appears in
  `kAXWindowsAttribute`, then hit-tested into an `AXUIElement` via
  `AXUIElementCopyElementAtPosition` — select a playlist, click a track row by label, screenshot).
  `Scenarios.swift` is the ~21-scenario suite (`Report.swift`'s `ScenarioCategory` distinguishes
  plain `ui` scenarios from `regression`/`codeInvariant`/`obsolete` ones); `main.swift` is the CLI
  entry (`--bundle-id`/`--report`/`--screenshot-dir`/`--wait-timeout`/`--skip-ytdlp-outage`).
  **`21-stream-resolve-timeout-bounded`** (added 2026-08-13, regression coverage for
  `playback-engine-007`): temporarily renames the real `yt-dlp` aside and writes a shim in its
  place that hangs 30s on its first-ever invocation (via `exec sleep 30`, replacing the shell's
  own process image so `process.terminate()` kills the actual hung process directly, not a
  forked child of it) then delegates to the real, hidden binary on every call after — same
  reversible rename-and-restore shape as `17-ytdlp-outage-error-handling`'s existing pattern, but
  this scenario *also* writes new content back to the original path, which its first version's
  `FileManager.moveItem`-based cleanup didn't account for (that call throws, silently via `try?`,
  when its destination already exists) — every run left the shim in place, papered over only by
  `Scripts/qc.sh`'s own `mv`-based safety net, until fixed to clear the destination first. Switches
  to a different playlist, then to the shimmed target, as its trigger (found live: reselecting an
  already-active playlist wasn't always a reliable fresh trigger, and a naive single global
  "has this ever hung" marker could race against `NextTrackPreloader`'s own background resolve for
  a different track). Still has known, harmless (never false-positive) residual timing flakiness
  — see its own doc comment and `playback-engine-007`'s "Live verification" note for the full
  account of what was chased down versus what's still open.
  **Readiness-check race, found and fixed 2026-08-13** on this harness's first real end-to-end
  run: `main.swift`'s startup wait treated successfully constructing `PopoverController` (which
  only confirms the app process is registered with `NSRunningApplication`) as "the app is ready" —
  but that happens as soon as `open` returns, well before SwiftUI has actually finished setting up
  `MenuBarExtra`'s status item. Every one of ~18 scenarios failed identically and instantly
  (`0.0s`, "app has no AXExtrasMenuBar") because the whole suite ran before the status item
  genuinely existed — confirmed as a harness-only bug, not a real regression, by querying the same
  running app directly via `osascript`/System Events immediately afterward and getting a valid
  `AXExtrasMenuBar` back. Fixed by folding a `statusItemLabel()` check into the same readiness
  wait, so "ready" now means the status item is actually queryable, not just that the process
  exists.
- `Scripts/qc.sh` — orchestrates the harness: kills any running instance, clean-builds via
  `package-app.sh`, builds `QCHarness`, launches, runs the full scenario suite, writes
  `qc-report.json` + `qc-screenshots/` (both gitignored), prints a pass/fail summary, and restores
  `yt-dlp` if an interrupted run left it renamed (belt-and-suspenders on top of the harness's own
  `defer`-based restore). The `qc` skill now runs this first — see SPEC.md.

No test suite yet — flagged in `issues/app-shell/001-menu-bar-scaffold.md` rather than added
unilaterally; every issue was instead verified with standalone `swift` scripts run outside the
package, most against the real YouTube playlists and real yt-dlp/AVPlayer/SMAppService/
MPNowPlayingInfoCenter behavior (see each issue file's Notes for exactly what was checked and,
where relevant, what real bugs were caught and fixed along the way — most notably the WebM/Opus
playback failure in `StreamResolver` and the `SMAppService` bundle-identity requirement).

## Status

All 56 issues across all 10 features are implemented, and — as of 2026-08-11 — **every feature in
`issues/FEATURES.md` is `qc-passed`**: the project has cleared per-feature QC (the `qc` skill's
human test pass, started 2026-08-09). `issues/volume-control/` grew from 2 to 8 issues on
2026-08-09 to cover automatic loudness normalization (see below); a 10th feature, **bgm**, was
added 2026-08-10 (13 issues after gaining 2 more on 2026-08-11, done — see its own entry below)
and had a first QC attempt blocked by a real startup-latency bug, since fixed, before eventually
reaching `qc-passed` on its third pass. "Every feature `qc-passed`" isn't the same as "gap-free" —
see the accepted/deferred gaps noted in the `playback-engine`, `startup`/`system-integration`, and
"Known gaps" entries below — and a full-project `/security-review` across the whole codebase is
still recommended (not yet run) before considering this release-ready.

- **app-shell**: `qc-passed`.
- **playlist-data**: `qc-passed` (2026-08-09). Full pass against the real playlists: cache-first
  instant load, a genuine cold scan for a never-loaded playlist (Drum'N'Bass, 1,750 tracks),
  stale-cache (>24h) background refresh actually replacing the on-disk cache, cache integrity
  surviving a failed background refresh, and safe plain-text rendering of CJK/ampersand track
  titles. The mid-pass block from the earlier menu-bar-ui display bugs is resolved.
- **menu-bar-ui**: `qc-passed` (originally 2026-08-09; re-confirmed with a fresh full pass
  2026-08-12 after the icon-only change below), 6/6 done. History: an earlier pass found and fixed
  two rendering bugs (menu-bar-ui-003/004, see
  their "Fix (2026-08-09)" notes) and passed all 7 scenarios including a live yt-dlp-absent/
  relaunch test. A follow-up scenario during playlist-data QC — disabling yt-dlp *mid-session*
  (not just at launch) — then caught two more real bugs in menu-bar-ui-005's error handling:
  duplicate stacked error messages, and the entire track list vanishing (not just playback
  stopping) on a resolution failure. Both fixed (see menu-bar-ui-005's "Fix (2026-08-09)" note and
  the `ContentView.swift`/`PlaybackController.swift` entries above) and re-verified live. Then
  gained and completed a new issue, `menu-bar-ui-006` (loading/buffering visual feedback across
  playlist-switch/fresh-resolve/stall wait moments, consuming `playback-engine-005`'s `isBuffering`
  signal) — see the `ContentView.swift` entry above; verified live.
  **Post-QC change, 2026-08-12** (via `/interview`, not a reopened issue): the menu bar label
  dropped its track-title text entirely in favor of icon-only + a playing/paused glyph swap, to
  fix the user's real menu-bar-overflow problem (icon getting hidden, no track-title text/
  tooltip visible in it anymore as a deliberate trade-off) — see the `PlaylistBarApp.swift` entry
  above for the full writeup, including the `.help()` tooltip attempt that was tried and reverted
  after confirming live it doesn't render on `MenuBarExtra` status items. Live-verified twice by
  the user against the real packaged `.app` (once with the tooltip attempt, once after reverting
  it) — icon-only label and the playing/paused glyph swap both confirmed correct on screen.
  **`/qc` pass, 2026-08-12**: all 5 in-scope scenarios passed live — icon-only label, the
  playing/paused glyph swap, the playlist selector (all 4 fixed playlists + BGM, switching
  works), transport controls (Previous/Next/Reset/Play-Pause), and the track list
  (previous-5/current/next-5, current highlighted, click-to-play). `menu-bar-ui-005`
  (yt-dlp-missing messaging) and `menu-bar-ui-006` (loading/buffering spinner) were **not**
  re-run this pass — by design, nothing in today's change touched either path, mirroring
  `playback-engine`'s 2026-08-11 precedent of skipping an unchanged scenario rather than
  re-confirming it for its own sake.
- **playback-engine**: `qc-passed` (originally 2026-08-09; re-confirmed with a fresh full pass
  2026-08-11 after `playback-engine-006` landed). 2026-08-09 pass covered: basic playback,
  natural-end auto-advance, gapless preload, rapid manual Previous/Next/track-click navigation.
  The natural-end auto-advance scenario **failed on first try** that day — stuck loading spinner,
  no advance — but investigation traced it to a real bug in `volume-control-007`'s code (a
  `withTaskGroup` race that never actually bounded latency), not to anything in `playback-engine`
  itself; see `volume-control-007`'s "QC feedback" note and the `LoudnessGainCoordinator.swift`
  entry above for the full writeup. Fixed and re-verified live, after which the scenario passed
  cleanly. Earlier history: QC had previously caught auto-advance silently not happening on a real
  full-length natural playthrough; first diagnosis (YouTube CDN throttling) turned out to be
  **wrong** — corrected once the real cause was found while implementing `playback-engine-005`:
  `AVFoundation` miscalculates duration (~2x too long) for these streams, so real audio played
  correctly then went genuinely silent for a long stretch before the app recognized the track as
  over. Fixed with a trusted-duration watchdog fed by yt-dlp's own metadata instead of
  `AVFoundation`'s broken one — see `AudioPlayer.swift`/`StreamResolver.swift` above and
  playback-engine-005's "Fix" note. Verified both via a standalone script (145.0s vs the old
  284.7s for a real previously-broken track) and live. App Nap prevention (added mid-investigation)
  is real hardening worth keeping, but wasn't the actual cause either.
  **2026-08-11 re-pass** (after `playback-engine-006`, seek-to-start-position with near-end clamp,
  landed as part of the per-track seek-position-resume backlog — see SPEC.md): live-verified basic
  playback, pause/resume, manual Next, and — the new behavior — resuming a track's saved position
  after switching playlists away and back (confirmed audibly resuming mid-track, not at 0:00).
  Natural end-of-track auto-advance was **not** re-run this pass (by user decision — nothing in
  that code path changed since its thorough 2026-08-09 live verification above, not worth several
  more minutes of real playback to reconfirm unchanged behavior).
  **Two accepted, permanently-deferred gaps** (explicit user decision 2026-08-11, not planned to be
  revisited): the near-end clamp (a saved position within ~5s of a track's end should resume at
  0:00 instead) has no practical live-test path — this app deliberately has no visible
  duration/scrub UI (see SPEC.md), so there's no way to time a manual test precisely — user judged
  this low-stakes (won't break anything if it's ever wrong) and accepted the existing standalone-
  script verification (see `playback-engine-006`'s Notes) as sufficient, permanently, not just for
  this pass. Unavailable-track auto-skip (`playback-engine-004`) has no UI path to inject a fake/
  dead video id into a real fixed playlist to force it live — user accepted the existing
  standalone-script verification (see that issue's Notes) as sufficient here too. Both are
  deliberately *not* being carried forward as open action items in future `/qc` passes.
  **Gained and completed a new issue, 2026-08-13** (`playback-engine-007`, found live via
  `/interview` after a real stuck-spinner incident — see the `YtDlpRunner.swift`/
  `StreamResolver.swift`/`AudioPlayer.swift` entries above and SPEC.md's "Resolution and buffering
  timeouts"): bounded timeouts for stream resolution (10s) and playback buffering (20s), both
  previously unbounded and both capable of stranding the UI on a permanent loading spinner forever
  — unlike the loudness-analysis wait, which was already correctly bounded. Either timeout now
  auto-skips to the next track, same as an unavailable one.
  **Live-verified the same day (2026-08-13)**, with the user's explicit go-ahead to briefly swap
  their real `yt-dlp` for a slow shim: a new permanent regression scenario,
  `21-stream-resolve-timeout-bounded` (see the `Sources/QCHarness/` entry below), confirmed the
  resolve-timeout half end-to-end — clean runs clear the loading spinner in ~12-18s and land on a
  genuinely playable track, and an out-of-band `ps`-based process monitor independently confirmed
  the hung shim subprocess is actually killed (observed alive, then genuinely gone, well inside
  the 10s bound), not just abandoned in the background. Two real bugs were found and fixed along
  the way, both in the *test scaffolding*, not the production fix: a `FileManager.moveItem`
  cleanup bug that silently failed to restore the real binary every run, and residual (safe, never
  false-positive) timing flakiness in the scenario's trigger setup — see
  `playback-engine-007`'s "Live verification" note for the full account, including what's still
  open. The playback-buffering-watchdog half (the other, harder-to-force half of this issue) was
  **not** separately live-verified — would need meaningfully more new test infrastructure (a local
  server that stalls mid-response) than was in scope for this pass; still resting on code review
  and the same already-proven pattern. Given the resolve-timeout half now has real, repeated,
  independently-confirmed live verification, this is no longer treated as an unverified gap the
  way it was earlier the same day — the buffering-watchdog half remains the one part still worth
  a dedicated future pass.
  **`/qc` pass, 2026-08-13 — re-confirmed `qc-passed`**: the automated harness (20/21 scenarios
  passed, one obsolete skip — see `Sources/QCHarness/` above) re-verified every previously-passing
  scenario across this and other bundled features with no regression from tonight's changes, plus
  the new `21-stream-resolve-timeout-bounded` regression scenario specifically covering
  `playback-engine-007`'s resolve-timeout half (repeated clean passes, ~12-18s, plus an
  independent out-of-band process-kill confirmation — see above). Not exhaustive: the
  buffering-watchdog half of `playback-engine-007` remains an open, disclosed gap (not
  live-verified, not permanently accepted the way the two 2026-08-11 gaps are) — worth a dedicated
  future pass with purpose-built stalling-server infrastructure, not treated as blocking this
  promotion back to `qc-passed` given everything else re-confirmed cleanly.
- **player-state**: `qc-passed` (2026-08-11, first full pass — previously `ready-for-qc`/
  `not-ready`, never tested as its own feature before). `player-state-001`/`002` (last-played-
  track and last-active-playlist persistence) and the newer `player-state-003` (seek-position
  persistence, part of the 2026-08-11 resume backlog) were all live-verified together via an
  actual Quit + relaunch (not just switching playlists while the app stays running, which
  `playback-engine`'s pass above already covered): the restored playlist, track, and seek position
  all matched what was left before quitting, with no auto-play, and a never-before-played playlist
  correctly defaulted to track 1.
- **playback-controller**: `qc-passed` (2026-08-11, first full pass — previously `ready-for-qc`/
  `not-ready`). Live-verified: clean playlist-switch handoff (no overlapping audio), Previous/Next
  wrap-around at both ends, Reset (jumps to track 1 at 0:00 even from a non-zero position
  elsewhere), click-to-play from the track list (starts fresh at 0:00), and the newer
  `playback-controller-006` resume wiring — specifically confirmed the interaction the issue's own
  Notes had flagged as not yet live-tested: after a fresh navigation action (click-to-play) resets
  a track's saved position, switching away and back correctly resumes at the *new* elapsed
  position, not a stale earlier one.
- **startup, system-integration**: `qc-passed` (2026-08-09), unchanged this round.
  **System media-key testing, previously an open gap** (`MPRemoteCommandCenter` targets were
  confirmed registered/enabled, but an actual key press was never simulated) **is now resolved**:
  user pressed the real play/pause media key during the 2026-08-11 QC session and confirmed it
  works correctly. F7/F8 (previous/next track) still haven't been physically pressed — narrower
  remaining gap than before, not reopened as a blocker.
- **volume-control**: `qc-passed` (2026-08-09), unchanged this round. Reframed 2026-08-09 (see
  SPEC.md's "Volume & loudness normalization"): two independent gain stages — a manual app-wide
  **master trim** (`001`/`002`) and automatic **per-track loudness normalization** (`003`–`008`)
  via `ffmpeg`'s `loudnorm` filter, cut-only toward -14 LUFS, cached permanently per track
  (`PlaylistCache.swift`), folded into the existing next-track preloader so forward listening never
  waits on it (`NextTrackPreloader.swift`, `LoudnessGainCoordinator.swift`), with a bounded 5s
  wait-then-fallback for out-of-order jumps (`PlaybackController.swift`) surfaced via the existing
  loading spinner (`ContentView.swift`). See the `Layout` entries above for each piece. A real bug
  in it was found, fixed, and live-verified on 2026-08-09 as a side effect of `playback-engine`'s
  QC (see `volume-control-007`'s "QC feedback" note and the `LoudnessGainCoordinator.swift` entry
  above): a `withTaskGroup`-based timeout race that never actually bounded latency in practice.
  `ffmpeg` is now installed on this machine and confirmed working end-to-end. Still worth knowing:
  whether a persistently-missing `ffmpeg` should get a UI banner (like `menu-bar-ui-005`'s yt-dlp
  one) or just silently degrade (every track plays unnormalized) was deliberately left an open
  question in `volume-control-003`'s Notes, not decided — currently it silently degrades, which
  may or may not be the right call.
- **bgm**: `qc-passed` (2026-08-11, see the third pass below), 13/13 done — added 2026-08-10 (see
  SPEC.md's "BGM channel playback"), a
  5th playlist-picker entry that plays random 15+ minute, non-members-only videos from a pool of
  YouTube channels, weighted toward whichever's been listened to least locally. All 11 issues are
  implemented — see the `Layout` entries above (`BGMCache.swift`, `BGMChannelScanner.swift`,
  `BGMChannels.swift`/`BGMLoader.swift`, `BGMSelector.swift`, `BGMListenTracker.swift` +
  `AudioPlayer.currentTime`/`restart()`/`itemTracksObserver`, `PlaybackController.swift`'s BGM
  integration, `StreamResolver.swift`'s `preferProgressive`, and `ContentView.swift`'s
  picker/track-list entries) for what each piece does and the scope decisions made along the way.
  **QC attempted 2026-08-10, blocked and reopened, then fixed**: the very first scenario (selecting
  "BGM") got stuck on a loading spinner for several minutes with no audio, reproduced twice live.
  Root cause: `AVPlayer` itself being slow to become ready-to-play for BGM's long (15 min–1 hr+),
  `moov`-atom-at-end audio-only streams — not a bug in this feature's own orchestration code, which
  was verified correct via live instrumentation. Fixed via `/interview` decision: BGM now resolves
  a faststart format instead (`StreamResolver.resolve(preferProgressive: true)`), dropping
  per-track loudness normalization for BGM as a consequence (see `PlaybackController.swift`'s
  `playBGM` entry above, and SPEC.md's "BGM channel playback" — "Startup latency for long videos" —
  for the full writeup and rejected alternatives). Verified live: cleared the BGM cache to force a
  fresh channel scan (matching the original repro) and confirmed BGM now plays quickly.

  **Second full `/qc` pass, 2026-08-10**: 10 of 11 scenarios passed cleanly (resume-a-restored-
  session, BGM track list shape, Next, Previous, Next-after-Previous discard-forward, click-a-
  history-entry, Reset, listen-count increment — cross-checked directly against `bgm-pool.json` —
  master volume during BGM, and restore-on-relaunch). One scenario failed: switching away from BGM
  to a fixed playlist and back duplicated the resumed track in the session history/track list.
  Reopened and fixed as `bgm-006`'s second pass (see that issue's "Fix (2026-08-10, second pass)"
  note and the `PlaybackController.swift` entry above) — `switchToBGM()` now resumes an
  already-known track in place instead of always appending. Re-verified live with two repeated
  switch-away/switch-back round-trips on the packaged app; no more duplicates. **Still not
  qc-passed** — this run confirmed the fix works but per this skill's own process a fix doesn't
  auto-promote the feature to `qc-passed`; a fresh confirmation `/qc` pass (or at minimum
  re-running the one previously-failing scenario) is what would actually close this out.
  `bgm-006`'s Notes list the remaining deliberate scope decisions worth knowing: no BGM-specific
  next-track preloader (a real, if usually brief, resolution gap on auto-advance, unlike the fixed
  playlists' gapless transition).

  **Gained and completed 2 new issues, 2026-08-11** (part of the per-track seek-position-resume
  backlog — see SPEC.md's "Local state (per playlist)"): `bgm-012` (persist/resume BGM's saved
  seek position) and `bgm-013` (measure the listen-count threshold relative to resume, not
  absolute position) — see the `PlaybackController.swift`/`BGMListenTracker.swift` entries above.

  **Third full `/qc` pass, 2026-08-11 — now `qc-passed`**: all 11 scenarios passed, including full
  re-confirmation of everything the second pass covered (select-BGM startup speed, track-list
  shape, Next, Previous, Next-after-Previous discards forward history, click-a-history-entry,
  Reset, master volume, switch-away-and-back with no duplicate history entry) plus the two new
  behaviors from `bgm-012`/`bgm-013`: resuming BGM's saved position both via a live switch-away/
  switch-back *and* via an actual Quit+relaunch (both confirmed audibly resuming mid-video, not at
  0:00), and the listen-count threshold now being measured relative to the resume point — verified
  directly against `bgm-pool.json`: a video resumed at ~75s (already past the 30s absolute
  threshold) held at its pre-resume listen count immediately after resuming, then correctly
  incremented only after ~30s of *additional* real playback since the resume. This is the feature's
  first time reaching `qc-passed` — the second pass above found and fixed a real bug but a fix
  doesn't auto-promote status per this skill's own process, and a confirmation pass was still owed
  even before `bgm-012`/`bgm-013` added new scope to it.

With this pass, **every feature in `issues/FEATURES.md` is `qc-passed`** as of 2026-08-11 — the
project has cleared per-feature QC. That doesn't mean gap-free, though (see the accepted gaps under
`playback-engine` above and "Known gaps" below) — and a full-project `/security-review` (or the
multi-agent `ultrareview`) across the whole codebase, not just per-issue diffs, is still
recommended before considering this release-ready; not run yet, since it's a deliberate,
potentially billed pass rather than something to trigger unprompted.

Known gaps worth knowing about, not blockers:
- **Visual/interactive UI verification turned out to be possible after all**, just not via
  screenshot tooling in this environment (`screencapture` here captures this chat app's own
  window, not the real desktop/menu bar — confirmed, not just assumed) — the working approach is
  the user driving the real running app directly and reporting/screenshotting what they see. This
  is exactly how the two menu-bar-ui bugs above were found: state was always correct
  (confirmed via temporary debug prints), the bugs were purely in what actually rendered.
- **A git repository now exists** (initialized 2026-08-10, no remote yet), but neither automated
  review command works from here yet, for two different reasons: `/code-review` is reserved for
  explicit user invocation — an agent can't invoke it via the Skill tool
  (`disable-model-invocation`) — while `/security-review` *is* agent-invocable but its diff logic
  is hardcoded against `origin/HEAD`, which fails outright with no remote configured (confirmed by
  trying it during `bgm-002`). Adding a remote isn't something to do unilaterally just to unblock
  this. All issues implemented so far, including every `bgm-*` one, are still going through a
  manual self-review pass instead, noted in each issue's own Notes. One real finding *was* caught
  via manual review pre-git (the PATH-resolution issue in `YtDlpAvailability.swift`, now fixed) —
  running the real `/code-review` command yourself over the current diff, and setting up a remote
  so `/security-review` can run too, would likely catch
  more than the manual passes have.
- **System media-key play/pause is now live-verified** (2026-08-11) — previously an open gap
  (`MPRemoteCommandCenter` targets confirmed registered/enabled, but no real key press simulated).
  F7/F8 (previous/next track) specifically still haven't been pressed — narrow remaining gap, not
  a blocker.
- **Near-end seek-position clamp and unavailable-track auto-skip are permanently accepted as
  standalone-script-verified-only** (explicit user decision, 2026-08-11) — not live-testable in
  practice (no scrub/duration UI for the former, no way to inject a dead video id into a real
  playlist for the latter) and judged low-stakes enough not to be worth chasing further. Not
  planned to be reopened in future `/qc` passes.
