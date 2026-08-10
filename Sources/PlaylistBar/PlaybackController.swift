import Foundation
import MediaPlayer

/// Ties playlist data, playback, and saved position together: switching to a playlist loads its
/// (cache-first) track list, resumes its saved position (or track 1), and plays immediately.
@MainActor
final class PlaybackController: ObservableObject {
    // Now Playing info (system-integration-001) is driven reactively off these `didSet`s rather
    // than called imperatively at each call site — every state-mutating method funnels through
    // these same properties, so this can't drift out of sync the way sprinkling explicit update
    // calls across switchTo/play/togglePlayPause/advanceOnFinish could.
    @Published private(set) var currentPlaylist: Playlist? {
        didSet { updateNowPlayingInfo() }
    }
    @Published private(set) var tracks: [CachedTrack] = []
    @Published private(set) var currentIndex: Int? {
        didSet { updateNowPlayingInfo() }
    }
    @Published private(set) var isLoading = false
    /// True while `play(startingAt:generation:)` is awaiting a fresh stream resolution — i.e. a
    /// track is starting for the first time, as opposed to `togglePlayPause()` resuming an
    /// already-loaded item. Surfaced for `menu-bar-ui-006`'s loading feedback.
    @Published private(set) var isResolvingTrack = false
    /// True while `play(startingAt:generation:)` is waiting (bounded) on loudness analysis for a
    /// track with no cached gain yet — an out-of-order jump, or the auto-advance fallback when a
    /// preload didn't finish in time. See `LoudnessGainCoordinator.gain(for:url:playlistSlug:
    /// timeout:)`. Surfaced for volume-control-008's loading feedback.
    @Published private(set) var isAwaitingLoudnessAnalysis = false
    @Published private(set) var isPlaying = false {
        didSet { updateNowPlayingInfo() }
    }
    /// Mirrors `AudioPlayer.isBuffering` — surfaced for `menu-bar-ui-006`'s loading/buffering
    /// feedback. See its doc comment there for why this is driven off `AVPlayer.timeControlStatus`
    /// rather than a custom heuristic.
    @Published private(set) var isBuffering = false
    /// App-wide master volume trim (0.0–1.0), independent of system/macOS volume — see
    /// `AudioPlayer.volume`. Persisted across relaunch via `PlayerStateStore`; volume-control-002
    /// wires this to a dropdown slider.
    @Published private(set) var masterVolume: Double
    /// A distinct, user-facing message for a scan or stream-resolution failure — as opposed to
    /// "every track happens to be unavailable", which isn't an error. Cleared on the next
    /// successful operation. Used by menu-bar-ui-005.
    @Published private(set) var errorMessage: String?

    private let loader = PlaylistLoader()
    private let player = AudioPlayer()
    private let preloader = NextTrackPreloader()
    private let loudnessCoordinator = LoudnessGainCoordinator()
    private let bgmLoader = BGMLoader()
    private let bgmListenTracker = BGMListenTracker()

    /// The playlist-picker slug BGM uses — not one of `FixedPlaylists.all`, but reuses the same
    /// per-slug `PlayerStateStore` persistence (last-played track, last-active playlist) as the 4
    /// fixed playlists. `currentPlaylist` is set to `Self.bgmPlaylist` while BGM is active — see
    /// `switchToBGM()`.
    static let bgmPlaylistSlug = "bgm"

    /// The synthetic `Playlist` value BGM uses for `currentPlaylist` — a single shared constant
    /// (not constructed ad hoc at each call site) because `Playlist`'s `Equatable`/`Hashable`
    /// conformance is field-based (slug/name/url, not just `id`), so the picker's tag comparison
    /// (`bgm-010`) would silently break if two call sites ever constructed slightly different
    /// literal values for it.
    static let bgmPlaylist = Playlist(slug: bgmPlaylistSlug, name: "BGM", url: "")

    /// True whenever BGM (not one of the 4 fixed playlists) is the active selection. Derived from
    /// `currentPlaylist` rather than a separate flag, so it can never drift out of sync with it.
    var isBGMActive: Bool { currentPlaylist?.slug == Self.bgmPlaylistSlug }

    /// Videos actually played during BGM this session, in play order — used by `Previous`
    /// (bgm-007, not yet implemented) to walk backward. Deliberately **not** persisted (see
    /// SPEC.md's "BGM channel playback": session-only, starts empty on every launch) and, unlike
    /// `switchTo(playlist:)`'s full state reset, **not** cleared on every `switchToBGM()` call —
    /// only reset by a fresh app launch — so switching away to a fixed playlist and back to BGM
    /// within the same session keeps the history intact.
    @Published private(set) var bgmHistory: [BGMTrack] = []

    /// Position within `bgmHistory` currently being played via Previous navigation (bgm-007) —
    /// `nil` means "at the live edge" (the most recently played video, `bgmHistory.last`). Reset
    /// to `nil` on `switchToBGM()` and whenever a fresh pick is made via `advanceBGM` (manual Next
    /// or natural auto-advance) — see `advanceBGM`'s "Next always picks fresh, discarding forward
    /// history" handling.
    private var bgmHistoryPosition: Int?

    /// `bgmHistory`'s index currently being displayed/played — `bgmHistoryPosition` if set (mid
    /// walk-back), otherwise the live edge (`bgmHistory.count - 1`). `nil` only when there's no
    /// BGM history at all yet. Exposed (rather than `bgmHistoryPosition` itself, an implementation
    /// detail) for `bgm-011`'s history-aware track list to window/highlight against. Not
    /// `@Published` itself, but every call that changes `bgmHistoryPosition` also changes
    /// `tracks`/`currentIndex` (both `@Published`) in the same method, so SwiftUI still
    /// re-evaluates this correctly on the next render.
    var bgmCurrentHistoryIndex: Int? {
        guard !bgmHistory.isEmpty else { return nil }
        return bgmHistoryPosition ?? (bgmHistory.count - 1)
    }

    /// Guards against a second state-mutating call (switchTo/previous/next/...) starting before
    /// an earlier one has finished resolving — without this, a fast double-action could let an
    /// earlier call's stale result overwrite a later one's state after the fact.
    private var switchGeneration = 0

    /// True once a resolved stream URL has actually been handed to `player.load`. Distinguishes
    /// "currentIndex is set because we're actively playing/paused on it" from "currentIndex is
    /// set because startup-002 restored it for display only, without loading anything into the
    /// player yet" — `togglePlayPause()` needs this to know whether Play should resume the
    /// existing item or resolve-and-start one for the first time.
    private var hasLoadedCurrentTrack = false

    /// How long `play(startingAt:generation:)` waits for loudness analysis on a track with no
    /// cached gain before giving up and playing unnormalized — see
    /// `LoudnessGainCoordinator.gain(for:url:playlistSlug:timeout:)`. Not specified further by
    /// SPEC.md; a few seconds is enough for a single-pass `ffmpeg` analysis of a full track under
    /// normal network conditions without making an out-of-order jump feel sluggish.
    private static let loudnessAnalysisTimeout: Duration = .seconds(5)

    init() {
        masterVolume = PlayerStateStore.masterVolume()
        applyEffectiveVolume()

        player.setOnFinish { [weak self] in
            Task { @MainActor [weak self] in
                await self?.advanceOnFinish()
            }
        }
        player.setOnBufferingChange { [weak self] isBuffering in
            self?.isBuffering = isBuffering
        }
        loudnessCoordinator.onGainMeasured = { [weak self] videoID, gain in
            self?.updateCachedGain(videoID: videoID, gain: gain)
        }
        setUpRemoteCommands()

        // Keeps `tracks` in sync with a background stale-cache refresh that completes after the
        // switchTo/restoreLastSession call that triggered it has already returned — without
        // this, the displayed list silently stays on the pre-refresh snapshot forever. Safe to
        // apply unconditionally: PlaylistLoader only ever holds data for whichever playlist load
        // is currently active (a superseded load is cancelled before a new one starts, and a
        // cancelled scan's result is never applied — see PlaylistLoader.rescanAndStore).
        loader.onTracksUpdated = { [weak self] newTracks in
            self?.tracks = newTracks
        }
    }

    /// Wires system-wide media keys (F7/F8/F9) and Control Center's media controls to the same
    /// actions as the in-dropdown transport buttons — works whether or not the dropdown is open.
    /// No Reset command: there's no standard system media-key equivalent for it.
    private func setUpRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in await self.previous() }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in await self.next() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in await self.togglePlayPause() }
            return .success
        }

        // Some clients (e.g. Control Center's own play/pause buttons) send discrete play/pause
        // rather than a single toggle — wire those too, each only acting when it's actually the
        // right direction.
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, !self.isPlaying else { return .commandFailed }
            Task { @MainActor in await self.togglePlayPause() }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying else { return .commandFailed }
            Task { @MainActor in await self.togglePlayPause() }
            return .success
        }
    }

    /// Switches to `playlist`: stops whatever was playing, loads the playlist's track list
    /// (instantly from cache when present), resumes its saved last-played track (or track 1 if
    /// never played), and starts playing immediately.
    func switchTo(playlist: Playlist) async {
        switchGeneration += 1
        let generation = switchGeneration

        player.stop()
        preloader.cancel()
        // A still-armed BGM listen tracker would otherwise keep polling `player.currentTime`
        // against whatever this fixed playlist now loads, and could misattribute a listen to the
        // BGM video that's no longer playing — see bgm-005's wiring note.
        bgmListenTracker.cancel()
        isPlaying = false
        hasLoadedCurrentTrack = false
        currentIndex = nil
        tracks = []

        guard let startIndex = await loadAndDetermineStartIndex(for: playlist, generation: generation) else {
            return
        }

        await play(startingAt: startIndex, generation: generation)
    }

    /// Switches to BGM: loads the pooled channel cache (bgm-003, cache-first), resumes the
    /// persisted last-played BGM video if one exists, otherwise picks a fresh weighted-random
    /// video (bgm-004), and starts playing it immediately — mirrors `switchTo(playlist:)`'s
    /// always-autoplay behavior. Unlike `switchTo(playlist:)`, does **not** reset `bgmHistory` —
    /// see its own doc comment for why.
    func switchToBGM() async {
        switchGeneration += 1
        let generation = switchGeneration

        player.stop()
        preloader.cancel()
        bgmListenTracker.cancel()
        isPlaying = false
        hasLoadedCurrentTrack = false
        currentPlaylist = Self.bgmPlaylist
        currentIndex = nil
        tracks = []
        bgmHistoryPosition = nil

        await bgmLoader.load()
        guard generation == switchGeneration else { return }

        let pool = bgmLoader.tracks
        guard !pool.isEmpty else {
            errorMessage = bgmLoader.lastScanErrorMessage
            return
        }
        errorMessage = nil

        let savedVideoID = PlayerStateStore.lastPlayedTrack(forPlaylistSlug: Self.bgmPlaylistSlug)
        let startTrack = savedVideoID.flatMap { id in pool.first(where: { $0.videoID == id }) }
            ?? BGMSelector.selectNext(from: pool, excluding: nil)

        guard let startTrack else { return }
        await playBGM(startingFrom: startTrack, generation: generation, appendToHistory: true)
    }

    /// Picks a new BGM video (excluding whatever's currently playing, per `BGMSelector`) and
    /// plays it — the shared implementation behind both manual `next()` and BGM's auto-advance
    /// branch in `advanceOnFinish()`, same "one helper, two callers" shape as
    /// `play(startingAt:generation:)` serves the fixed-playlist equivalents.
    private func advanceBGM(generation: Int) async {
        guard let current = tracks.first else { return }
        guard let picked = BGMSelector.selectNext(from: bgmLoader.tracks, excluding: current.videoID) else {
            guard generation == switchGeneration else { return }
            player.stop()
            isPlaying = false
            currentIndex = nil
            tracks = []
            hasLoadedCurrentTrack = false
            return
        }

        // A fresh pick always discards any "forward" history left over from a prior Previous
        // walk-back — bgm-007's explicit decision: Next never redoes forward through history,
        // it always picks fresh and that becomes the new end of history.
        if let position = bgmHistoryPosition {
            bgmHistory = Array(bgmHistory.prefix(position + 1))
            bgmHistoryPosition = nil
        }

        await playBGM(startingFrom: picked, generation: generation, appendToHistory: true)
    }

    /// Walks backward through `bgmHistory` (like a browser back button) and replays that video —
    /// a no-op if there's no earlier entry (e.g. right after switching to BGM, on its first
    /// video). Doesn't grow `bgmHistory` (the target is already in it) or change the persisted
    /// last-active playlist beyond the usual "this is now playing" update `playBGM` already does.
    private func previousBGM() async {
        let currentPosition = bgmHistoryPosition ?? (bgmHistory.count - 1)
        let newPosition = currentPosition - 1
        guard bgmHistory.indices.contains(newPosition) else { return }

        switchGeneration += 1
        let generation = switchGeneration
        bgmHistoryPosition = newPosition
        await playBGM(startingFrom: bgmHistory[newPosition], generation: generation, appendToHistory: false)
    }

    /// Jumps directly to `bgmHistory[index]` (e.g. a click on a past entry in the BGM track list —
    /// bgm-011) — same effect as pressing Previous repeatedly until reaching that point. A no-op
    /// for an out-of-range index, or when BGM isn't the active selection.
    func selectBGMHistoryEntry(at index: Int) async {
        guard isBGMActive, bgmHistory.indices.contains(index) else { return }

        switchGeneration += 1
        let generation = switchGeneration
        bgmHistoryPosition = index == bgmHistory.count - 1 ? nil : index
        await playBGM(startingFrom: bgmHistory[index], generation: generation, appendToHistory: false)
    }

    /// Resolves and plays `startingTrack`, auto-skipping to another weighted-random pick (bounded
    /// by pool size — same "never hang even if everything's unavailable" guarantee as
    /// `TrackAvailabilityResolver`) if it turns out to be unavailable or otherwise fails to
    /// resolve. On success, persists the track as the new BGM position, appends it to
    /// `bgmHistory`, and arms `bgmListenTracker` for it.
    ///
    /// Represents the "current track" via the same `tracks`/`currentIndex` mechanism the 4 fixed
    /// playlists use (a single-element `tracks` array, `currentIndex = 0`) rather than separate
    /// BGM-specific published state — this is what makes `updateNowPlayingInfo()`, the menu bar
    /// title, and `applyEffectiveVolume()`/`currentTrackGain` all work correctly for BGM with no
    /// changes to any of them.
    private func playBGM(
        startingFrom startingTrack: BGMTrack, generation: Int, appendToHistory: Bool
    ) async {
        var candidate = startingTrack
        var excludedVideoIDs: Set<String> = []
        var attemptsRemaining = max(bgmLoader.tracks.count, 1)

        while attemptsRemaining > 0 {
            attemptsRemaining -= 1
            guard generation == switchGeneration else { return }

            tracks = [CachedTrack(
                videoID: candidate.videoID, title: candidate.title,
                normalizationGain: candidate.normalizationGain
            )]
            currentIndex = 0
            isResolvingTrack = true
            isAwaitingLoudnessAnalysis = false

            let resolution: StreamResolution
            do {
                let videoID = candidate.videoID
                resolution = try await Task.detached(priority: .utility) {
                    try StreamResolver.resolve(videoID: videoID)
                }.value
            } catch StreamResolver.ResolutionError.ytDlpNotFound {
                guard generation == switchGeneration else { return }
                isResolvingTrack = false
                player.stop()
                isPlaying = false
                hasLoadedCurrentTrack = false
                errorMessage = "yt-dlp not found — run `brew install yt-dlp`"
                return
            } catch {
                // Any other resolution failure is about this one video, not the pool as a whole —
                // treat it like .unavailable below rather than aborting BGM entirely.
                resolution = .unavailable
            }

            guard generation == switchGeneration else { return }
            isResolvingTrack = false

            guard case .available(let url, let duration) = resolution else {
                excludedVideoIDs.insert(candidate.videoID)
                let remainingPool = bgmLoader.tracks.filter { !excludedVideoIDs.contains($0.videoID) }
                guard let next = BGMSelector.selectNext(from: remainingPool, excluding: nil) else {
                    break
                }
                candidate = next
                continue
            }

            errorMessage = nil

            // Loudness normalization for BGM, deliberately simpler than the fixed-playlist path's
            // LoudnessGainCoordinator/NextTrackPreloader combo: no background preload head-start
            // (BGM's next pick isn't decided until it's needed, so there's nothing to preload
            // ahead of time — see this issue's Notes), and a standalone bounded wait rather than
            // sharing an in-flight-task cache. A timed-out-but-later-successful analysis is not
            // retroactively cached the way the fixed-playlist coordinator's is — a smaller
            // regression than skipping normalization for BGM entirely, and simpler to reason
            // about; noted as a possible future improvement, not silently dropped.
            if candidate.normalizationGain == nil {
                isAwaitingLoudnessAnalysis = true
                let measured = await measureBGMGain(
                    url: url, timeout: Self.loudnessAnalysisTimeout
                )
                guard generation == switchGeneration else { return }
                isAwaitingLoudnessAnalysis = false
                if let measured {
                    BGMCacheStore.setNormalizationGain(measured, forVideoID: candidate.videoID)
                    if tracks.indices.contains(0) {
                        tracks[0].normalizationGain = measured
                    }
                }
            }

            applyEffectiveVolume()
            player.load(url: url, duration: duration, autoplay: true)
            hasLoadedCurrentTrack = true
            isPlaying = true

            PlayerStateStore.setLastPlayedTrack(candidate.videoID, forPlaylistSlug: Self.bgmPlaylistSlug)
            PlayerStateStore.setLastActivePlaylist(slug: Self.bgmPlaylistSlug)

            // A history walk-back (Previous, or clicking a past entry — bgm-007) replays a track
            // already present in `bgmHistory`; only a genuinely fresh pick (switchToBGM, Next,
            // auto-advance) should grow it.
            if appendToHistory {
                bgmHistory.append(candidate)
            }
            bgmListenTracker.start(
                videoID: candidate.videoID, duration: candidate.duration,
                currentTime: { [weak self] in self?.player.currentTime ?? 0 }
            )
            return
        }

        // Every candidate was tried (or the pool ran out mid-retry) with none playable.
        guard generation == switchGeneration else { return }
        player.stop()
        isPlaying = false
        currentIndex = nil
        tracks = []
        hasLoadedCurrentTrack = false
    }

    /// Measures loudness gain for a BGM track's resolved stream, bounded by `timeout` — same
    /// continuation-race shape as `LoudnessGainCoordinator.gain(for:url:playlistSlug:timeout:)`
    /// (avoiding `withTaskGroup`'s "waits for every child including the loser" pitfall — see that
    /// type's own Notes for the real bug that shape caused), but without an in-flight-task cache
    /// shared with a preloader, since BGM has none. Returns `nil` on timeout or genuine failure —
    /// never written back to the cache in that case, same "fallback isn't a measurement" rule.
    private func measureBGMGain(url: URL, timeout: Duration) async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            var hasResumed = false

            Task {
                let measured = try? await Task.detached(priority: .utility) {
                    try LoudnessAnalyzer.measureGain(url: url)
                }.value
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: measured)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Restores the last active playlist and its last-played track for display **without**
    /// starting playback — the one place SPEC.md's "switching plays immediately" rule
    /// deliberately doesn't apply, so the app doesn't start making noise unexpectedly right after
    /// login. Meant to be called once at app launch (see startup-002); a no-op if there's no
    /// prior session to restore.
    func restoreLastSession() async {
        guard let slug = PlayerStateStore.lastActivePlaylistSlug() else { return }

        if slug == Self.bgmPlaylistSlug {
            await restoreBGMSession()
            return
        }

        guard let playlist = FixedPlaylists.all.first(where: { $0.slug == slug }) else {
            return
        }

        switchGeneration += 1
        let generation = switchGeneration

        guard let startIndex = await loadAndDetermineStartIndex(for: playlist, generation: generation) else {
            return
        }

        currentIndex = startIndex
    }

    /// BGM equivalent of `restoreLastSession()`'s fixed-playlist path: loads the pooled cache
    /// (cache-first) and displays the persisted last-played BGM video — or a fresh weighted-random
    /// pick if there's no saved video yet — **without** resolving a stream or starting playback,
    /// same "restore for display only" contract `loadAndDetermineStartIndex` gives the fixed
    /// playlists. Seeds `bgmHistory` with the restored track so it behaves as the first (and, at
    /// this point, only) entry — pressing Previous immediately after a restore correctly has
    /// nothing earlier to go to.
    private func restoreBGMSession() async {
        switchGeneration += 1
        let generation = switchGeneration

        currentPlaylist = Self.bgmPlaylist
        bgmHistoryPosition = nil

        await bgmLoader.load()
        guard generation == switchGeneration else { return }

        let pool = bgmLoader.tracks
        guard !pool.isEmpty else {
            errorMessage = bgmLoader.lastScanErrorMessage
            return
        }
        errorMessage = nil

        let savedVideoID = PlayerStateStore.lastPlayedTrack(forPlaylistSlug: Self.bgmPlaylistSlug)
        let restoredTrack = savedVideoID.flatMap { id in pool.first(where: { $0.videoID == id }) }
            ?? BGMSelector.selectNext(from: pool, excluding: nil)

        guard let restoredTrack else { return }

        tracks = [CachedTrack(
            videoID: restoredTrack.videoID, title: restoredTrack.title,
            normalizationGain: restoredTrack.normalizationGain
        )]
        currentIndex = 0
        bgmHistory = [restoredTrack]
    }

    /// Loads (cache-first) `playlist`'s track list into `tracks`/`currentPlaylist`/`errorMessage`
    /// and returns the index to resume at (saved position, or 0 if never played) — or `nil` if
    /// the playlist has no tracks or a newer state-mutating call has superseded this one.
    private func loadAndDetermineStartIndex(for playlist: Playlist, generation: Int) async -> Int? {
        currentPlaylist = playlist
        isLoading = true
        await loader.load(playlistSlug: playlist.slug, playlistURL: playlist.url)
        isLoading = false

        guard generation == switchGeneration else { return nil }

        let loadedTracks = loader.tracks
        tracks = loadedTracks
        guard !loadedTracks.isEmpty else {
            errorMessage = loader.lastScanErrorMessage
            return nil
        }
        errorMessage = nil

        let savedVideoID = PlayerStateStore.lastPlayedTrack(forPlaylistSlug: playlist.slug)
        return savedVideoID.flatMap { id in loadedTracks.firstIndex(where: { $0.videoID == id }) } ?? 0
    }

    /// Toggles between playing and paused. If a track's index is known but nothing has actually
    /// been loaded into the player yet — the state right after `restoreLastSession()` — resolves
    /// and starts it fresh instead of resuming a nonexistent item. No-ops if no track is known at
    /// all (no active playlist).
    func togglePlayPause() async {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }

        guard let index = currentIndex else { return }

        if hasLoadedCurrentTrack {
            player.play()
            isPlaying = true
        } else if isBGMActive {
            // The state right after `restoreBGMSession()`: a track is displayed but never
            // resolved/played. Route through `playBGM` (not the fixed-playlist `play(startingAt:)`
            // below) so this first real play still gets BGM's own gain persistence, listen
            // tracking, and history bookkeeping — bailing cleanly if the restored video somehow
            // isn't in the pool anymore (e.g. a background refresh dropped it between restore and
            // this press) rather than guessing at its duration.
            guard let current = tracks.first,
                  let candidate = bgmLoader.tracks.first(where: { $0.videoID == current.videoID }) else {
                return
            }
            switchGeneration += 1
            let generation = switchGeneration
            await playBGM(startingFrom: candidate, generation: generation, appendToHistory: false)
        } else {
            switchGeneration += 1
            let generation = switchGeneration
            await play(startingAt: index, generation: generation)
        }
    }

    /// Sets the app-wide master volume trim (0.0–1.0), applying immediately to whatever's
    /// currently playing (no restart/reload) and persisting it across relaunch. Combines with
    /// the current track's normalization gain, if any — see `applyEffectiveVolume()`.
    func setMasterVolume(_ volume: Double) {
        let clamped = min(max(volume, 0.0), 1.0)
        masterVolume = clamped
        applyEffectiveVolume()
        PlayerStateStore.setMasterVolume(clamped)
    }

    /// The current track's cached per-track normalization gain (`LoudnessAnalyzer`, cut-only
    /// toward its target LUFS), or `1.0` if it hasn't been measured yet or there's no current
    /// track.
    private var currentTrackGain: Double {
        guard let index = currentIndex, tracks.indices.contains(index) else { return 1.0 }
        return tracks[index].normalizationGain ?? 1.0
    }

    /// Applies `masterVolume * currentTrackGain` to the player — the two independent gain stages
    /// SPEC.md's "Volume & loudness normalization" describes. Called whenever the master trim
    /// changes, and whenever a track starts (so its volume is correct from the first sample).
    /// Deliberately **not** called reactively whenever a track's cached gain is *measured* in the
    /// background (volume-control-007) — a track already playing unnormalized stays that way for
    /// the rest of that play, corrected only the next time it starts, avoiding an audible jump
    /// mid-track.
    private func applyEffectiveVolume() {
        player.volume = Float(masterVolume * currentTrackGain)
    }

    /// Steps to the previous track by playlist index, wrapping from the first track to the last.
    /// While BGM is active, this instead walks backward through the session's play history
    /// (bgm-007) — see `previousBGM()`.
    func previous() async {
        if isBGMActive {
            await previousBGM()
        } else {
            await step(by: -1)
        }
    }

    /// Steps to the next track by playlist index, wrapping from the last track to the first.
    /// While BGM is active, this instead picks a new video via `BGMSelector` (bgm-004).
    func next() async {
        if isBGMActive {
            switchGeneration += 1
            await advanceBGM(generation: switchGeneration)
        } else {
            await step(by: 1)
        }
    }

    /// Jumps to track 1 of the current playlist and plays it, becoming the new saved position.
    /// While BGM is active, Reset instead restarts the *current* video from 0:00 (`AudioPlayer.
    /// restart()`) — it doesn't pick a new video (Next already covers that), doesn't affect
    /// `bgmHistory`/`bgmHistoryPosition`, and doesn't need a `switchGeneration` bump since it
    /// isn't resolving anything new, just seeking what's already loaded.
    func reset() async {
        if isBGMActive {
            guard currentIndex != nil else { return }
            player.restart()
            isPlaying = true
            return
        }

        guard !tracks.isEmpty else { return }

        switchGeneration += 1
        let generation = switchGeneration

        await play(startingAt: 0, generation: generation)
    }

    /// Called when the currently playing track finishes naturally. Advances exactly like
    /// `next()` (wrap-around, unavailable-skip) — but tries the preloaded URL first
    /// (playback-engine-003) for a gapless transition, falling back to a fresh resolve only if
    /// no matching preload is ready (still in flight, failed, or the immediate next track turns
    /// out to be unavailable).
    private func advanceOnFinish() async {
        if isBGMActive {
            switchGeneration += 1
            await advanceBGM(generation: switchGeneration)
            return
        }

        guard !tracks.isEmpty, let current = currentIndex else { return }

        switchGeneration += 1
        let generation = switchGeneration

        let nextIndex = (current + 1) % tracks.count
        let nextTrack = tracks[nextIndex]

        if let preloaded = preloader.takePreloaded(for: nextTrack.videoID) {
            currentIndex = nextIndex
            applyEffectiveVolume()
            player.load(url: preloaded.url, duration: preloaded.duration, autoplay: true)
            hasLoadedCurrentTrack = true
            isPlaying = true
            if let slug = currentPlaylist?.slug {
                PlayerStateStore.setLastPlayedTrack(nextTrack.videoID, forPlaylistSlug: slug)
                PlayerStateStore.setLastActivePlaylist(slug: slug)
            }
            beginPreloadForNext()
        } else {
            await play(startingAt: nextIndex, generation: generation)
        }
    }

    /// Kicks off (or re-targets) a background preload for the track after the current one, so
    /// the next auto-advance has no perceptible resolution delay — and, per volume-control-006,
    /// no perceptible loudness-analysis delay either.
    private func beginPreloadForNext() {
        guard !tracks.isEmpty, let current = currentIndex, let slug = currentPlaylist?.slug else { return }
        preloader.beginPreload(
            tracks: tracks, currentIndex: current, playlistSlug: slug,
            loudnessCoordinator: loudnessCoordinator
        )
    }

    /// Updates a track's cached normalization gain in the in-memory `tracks` array — the disk
    /// cache is already updated by `LoudnessGainCoordinator` itself by the time this fires (see
    /// its `onGainMeasured`). Deliberately doesn't touch `applyEffectiveVolume()` — a track
    /// already playing unnormalized stays that way for the rest of that play, per its doc
    /// comment.
    private func updateCachedGain(videoID: String, gain: Double) {
        guard let index = tracks.firstIndex(where: { $0.videoID == videoID }) else { return }
        tracks[index].normalizationGain = gain
    }

    /// Jumps directly to the track at `index` (e.g. a click in the track list) and plays it,
    /// becoming the new saved position.
    func selectTrack(at index: Int) async {
        guard tracks.indices.contains(index) else { return }

        switchGeneration += 1
        let generation = switchGeneration

        await play(startingAt: index, generation: generation)
    }

    private func step(by offset: Int) async {
        guard !tracks.isEmpty, let current = currentIndex else { return }

        switchGeneration += 1
        let generation = switchGeneration

        let count = tracks.count
        let newIndex = ((current + offset) % count + count) % count
        await play(startingAt: newIndex, generation: generation)
    }

    /// Resolves and plays the first actually-playable track from `index` onward (auto-skipping
    /// unavailable ones, see `TrackAvailabilityResolver`), persisting it as the new saved
    /// position. Does nothing if a newer `switchTo` has superseded this one in the meantime.
    private func play(startingAt index: Int, generation: Int) async {
        guard !tracks.isEmpty else { return }

        // Set optimistically before resolving so the track list stays visible (centered on the
        // intended track) even while resolution is in flight or if it ends up failing below —
        // previously this was only set on success, so a resolution failure left `currentIndex`
        // nil and the entire track list (not just playback) disappeared, even though `tracks`
        // itself was still populated and correct.
        if generation == switchGeneration {
            currentIndex = index
            isResolvingTrack = true
            // A superseded call's own wait (below) can't clear this on its way out — only a
            // fresh call's entry, here, can safely say "nothing is being awaited yet" for the
            // now-current generation.
            isAwaitingLoudnessAnalysis = false
        }

        let resolution: PlayableResolution
        do {
            resolution = try await TrackAvailabilityResolver.resolveNextPlayable(
                tracks: tracks, startIndex: index
            )
        } catch StreamResolver.ResolutionError.ytDlpNotFound {
            guard generation == switchGeneration else { return }
            isResolvingTrack = false
            player.stop()
            isPlaying = false
            hasLoadedCurrentTrack = false
            errorMessage = "yt-dlp not found — run `brew install yt-dlp`"
            return
        } catch {
            guard generation == switchGeneration else { return }
            isResolvingTrack = false
            player.stop()
            isPlaying = false
            hasLoadedCurrentTrack = false
            errorMessage = "Couldn't play this track — check your network connection."
            return
        }

        guard generation == switchGeneration else { return }
        isResolvingTrack = false

        switch resolution {
        case .playable(let playableIndex, let url, let duration):
            currentIndex = playableIndex
            errorMessage = nil

            if tracks.indices.contains(playableIndex),
               tracks[playableIndex].normalizationGain == nil,
               let slug = currentPlaylist?.slug {
                isAwaitingLoudnessAnalysis = true
                _ = await loudnessCoordinator.gain(
                    for: tracks[playableIndex], url: url, playlistSlug: slug,
                    timeout: Self.loudnessAnalysisTimeout
                )
                // A newer call (e.g. the user clicked a different track while this one waited)
                // has since taken over — bail out *before* touching shared state, so this stale
                // call can't clobber `isAwaitingLoudnessAnalysis` (or the player) out from under
                // whatever the newer call has already done.
                guard generation == switchGeneration else { return }
                isAwaitingLoudnessAnalysis = false
            }

            applyEffectiveVolume()
            player.load(url: url, duration: duration, autoplay: true)
            hasLoadedCurrentTrack = true
            isPlaying = true
            if let slug = currentPlaylist?.slug, tracks.indices.contains(playableIndex) {
                PlayerStateStore.setLastPlayedTrack(tracks[playableIndex].videoID, forPlaylistSlug: slug)
                PlayerStateStore.setLastActivePlaylist(slug: slug)
            }
            beginPreloadForNext()
        case .noneAvailable:
            player.stop()
            isPlaying = false
            currentIndex = nil
            hasLoadedCurrentTrack = false
        }
    }

    /// Publishes (or clears) the current track/playlist and play state to Control Center's Now
    /// Playing widget and the lock screen.
    private func updateNowPlayingInfo() {
        guard let index = currentIndex, tracks.indices.contains(index) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: tracks[index].title,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let playlistName = currentPlaylist?.name {
            info[MPMediaItemPropertyAlbumTitle] = playlistName
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
