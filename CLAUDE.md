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
  label (icon + current track title, truncated) and `ContentView` as the dropdown content. Owns
  the single `PlaybackController` instance (shared between label and dropdown) and kicks off
  `restoreLastSession()` from the label's `.task` (the label, unlike the dropdown content, is
  instantiated immediately at launch — needed so the previous session is restored before the
  dropdown is ever opened). `AppDelegate` sets `.accessory` activation policy (no Dock icon). The
  label is built as an explicit `HStack { Image(systemName:); Text(menuBarTitle) }`, not
  `Label(_:systemImage:)` — a `MenuBarExtra` status item doesn't reliably render `Label`'s title
  text next to its icon (collapses to icon-only); found via QC on 2026-08-09, see menu-bar-ui-004.
  `menuBarTitle`'s truncation length was halved from 40 to 20 characters (2026-08-11, user report:
  the untruncated title was long enough to sometimes cover the system menu bar's battery icon) —
  confirmed via `/interview` that the more aggressive truncation this causes (e.g. "Never Gonna
  Give You Up" becoming "Never Gonna Give You…") is an acceptable tradeoff against covering system
  status icons.
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
  `start(videoID:duration:currentTime:)` arms a 1Hz `Timer` (same pattern as `AudioPlayer`'s own
  end-of-track watchdog — `Timer` + `RunLoop.main.add(_:forMode:)` + a `Task { @MainActor in }`
  hop, since a `Timer` callback isn't itself actor-isolated) that, once `currentTime()` crosses
  `min(30, duration * 0.2)`, calls `BGMCacheStore.incrementListenCount(forVideoID:)` exactly once
  and stops. `cancel()` stops without incrementing; `start()` always cancels any prior in-flight
  tracking first. **Wiring requirement for whatever calls this** (`bgm-006`): switching away from
  BGM to a fixed playlist must explicitly call `cancel()` — `start()`'s auto-cancel only covers
  switching *between* BGM videos, so a still-armed tracker left running after leaving BGM would
  keep polling `AudioPlayer.currentTime` against whatever's now loaded and could misattribute a
  listen to a video that's no longer playing.
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
  faststart) format selector — used by BGM only.
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
  and resumes advancing afterward with `rate == 1.0`. `itemTracksObserver` (added 2026-08-10 as
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
- `Sources/PlaylistBar/YtDlpAvailability.swift` — `YtDlpLocator.checkAvailability()`, a PATH
  (+ Homebrew dirs) check for `yt-dlp`.
- `Sources/PlaylistBar/YtDlpRunner.swift` — shared subprocess execution for yt-dlp: resolves its
  absolute path via `YtDlpLocator` (not bare-name PATH lookup) and runs it with an argument array,
  draining stdout/stderr concurrently to avoid a pipe-buffer deadlock on large output.
- `Sources/PlaylistBar/LoginItemManager.swift` — wraps `SMAppService.mainApp` register/unregister/
  status for the Launch-at-Login toggle. Only works against the real packaged `.app` (see
  `Scripts/package-app.sh` above) — throws against a bare `swift build` executable.
- `Packaging/Info.plist`, `Scripts/package-app.sh` — see "Build & run" above.

No test suite yet — flagged in `issues/app-shell/001-menu-bar-scaffold.md` rather than added
unilaterally; every issue was instead verified with standalone `swift` scripts run outside the
package, most against the real YouTube playlists and real yt-dlp/AVPlayer/SMAppService/
MPNowPlayingInfoCenter behavior (see each issue file's Notes for exactly what was checked and,
where relevant, what real bugs were caught and fixed along the way — most notably the WebM/Opus
playback failure in `StreamResolver` and the `SMAppService` bundle-identity requirement).

## Status

All 36 issues across the original 9 features are implemented (`issues/volume-control/` grew from 2
to 8 issues on 2026-08-09 to cover automatic loudness normalization — see below — and all 8 are
now done); QC (the `qc` skill's human test pass against `issues/FEATURES.md`) is in progress,
started 2026-08-09. A 10th feature, **bgm**, was added 2026-08-10 (11 issues, done — see its own
entry below) and had a first QC attempt blocked by a real startup-latency bug, since fixed; still
needs a fresh full QC pass of its own.

- **app-shell**: `qc-passed`.
- **playlist-data**: `qc-passed` (2026-08-09). Full pass against the real playlists: cache-first
  instant load, a genuine cold scan for a never-loaded playlist (Drum'N'Bass, 1,750 tracks),
  stale-cache (>24h) background refresh actually replacing the on-disk cache, cache integrity
  surviving a failed background refresh, and safe plain-text rendering of CJK/ampersand track
  titles. The mid-pass block from the earlier menu-bar-ui display bugs is resolved.
- **menu-bar-ui**: back to `ready-for-qc` (2026-08-09), 6/6 done, needs a fresh full pass (not yet
  re-run). History: an earlier pass found and fixed two rendering bugs (menu-bar-ui-003/004, see
  their "Fix (2026-08-09)" notes) and passed all 7 scenarios including a live yt-dlp-absent/
  relaunch test. A follow-up scenario during playlist-data QC — disabling yt-dlp *mid-session*
  (not just at launch) — then caught two more real bugs in menu-bar-ui-005's error handling:
  duplicate stacked error messages, and the entire track list vanishing (not just playback
  stopping) on a resolution failure. Both fixed (see menu-bar-ui-005's "Fix (2026-08-09)" note and
  the `ContentView.swift`/`PlaybackController.swift` entries above) and re-verified live. Then
  gained and completed a new issue, `menu-bar-ui-006` (loading/buffering visual feedback across
  playlist-switch/fresh-resolve/stall wait moments, consuming `playback-engine-005`'s `isBuffering`
  signal) — see the `ContentView.swift` entry above; verified live.
- **playback-engine**: `qc-passed` (2026-08-09, fresh full pass via `/qc`). Covered: basic
  playback, natural-end auto-advance, gapless preload, rapid manual Previous/Next/track-click
  navigation. The natural-end auto-advance scenario **failed on first try** — stuck loading
  spinner, no advance — but investigation traced it to a real bug in `volume-control-007`'s code
  (a `withTaskGroup` race that never actually bounded latency), not to anything in
  `playback-engine` itself; see `volume-control-007`'s "QC feedback" note and the
  `LoudnessGainCoordinator.swift` entry above for the full writeup. Fixed and re-verified live,
  after which the scenario passed cleanly. Unavailable-track auto-skip (`playback-engine-004`)
  couldn't be forced live — no UI path to inject a fake video id into a fixed real playlist — so
  that scenario relies on its existing standalone-script verification instead; noted as a gap,
  not silently skipped. Earlier history: QC had previously caught auto-advance silently not
  happening on a real full-length natural playthrough; first diagnosis (YouTube CDN throttling)
  turned out to be **wrong** — corrected once the real cause was found while implementing
  `playback-engine-005`: `AVFoundation` miscalculates duration (~2x too long) for these streams,
  so real audio played correctly then went genuinely silent for a long stretch before the app
  recognized the track as over. Fixed with a trusted-duration watchdog fed by yt-dlp's own
  metadata instead of `AVFoundation`'s broken one — see `AudioPlayer.swift`/`StreamResolver.swift`
  above and playback-engine-005's "Fix" note. Verified both via a standalone script (145.0s vs the
  old 284.7s for a real previously-broken track) and live. App Nap prevention (added mid-
  investigation) is real hardening worth keeping, but wasn't the actual cause either.
- **player-state, playback-controller, startup, system-integration**: still `ready-for-qc`, not
  yet started.
- **volume-control**: `ready-for-qc` (2026-08-09), 8/8 done, never yet QC'd (new feature).
  Reframed 2026-08-09 (see SPEC.md's "Volume & loudness normalization"): two independent gain
  stages — a manual app-wide **master trim** (`001`/`002`) and automatic **per-track loudness
  normalization** (`003`–`008`) via `ffmpeg`'s `loudnorm` filter, cut-only toward -14 LUFS, cached
  permanently per track (`PlaylistCache.swift`), folded into the existing next-track preloader so
  forward listening never waits on it (`NextTrackPreloader.swift`,
  `LoudnessGainCoordinator.swift`), with a bounded 5s wait-then-fallback for out-of-order jumps
  (`PlaybackController.swift`) surfaced via the existing loading spinner (`ContentView.swift`).
  See the `Layout` entries above for each piece. **Not yet QC'd as its own feature** — but a real
  bug in it was already found, fixed, and live-verified on 2026-08-09 as a side effect of
  `playback-engine`'s QC (see `volume-control-007`'s "QC feedback" note and the
  `LoudnessGainCoordinator.swift` entry above): a `withTaskGroup`-based timeout race that never
  actually bounded latency in practice. `ffmpeg` is now installed on this machine and confirmed
  working end-to-end. Still worth knowing: whether a persistently-missing `ffmpeg` should get a UI
  banner (like `menu-bar-ui-005`'s yt-dlp one) or just silently degrade (every track plays
  unnormalized) was deliberately left an open question in `volume-control-003`'s Notes, not
  decided — currently it silently degrades, which may or may not be the right call.
- **bgm**: `ready-for-qc` (2026-08-10), 11/11 done — added 2026-08-10 (see SPEC.md's "BGM channel
  playback"), a
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
- **System media-key/Control Center testing is unverified** — `MPRemoteCommandCenter` targets are
  confirmed registered and enabled, but an actual F7/F8/F9 press wasn't simulated (no way to do
  so without Accessibility/hardware access).
