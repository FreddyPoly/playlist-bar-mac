import Foundation

/// Local, per-playlist playback position — separate from `PlaylistCacheStore`'s track-list
/// cache, since this changes on every track change rather than every 24h scan.
enum PlayerStateStore {
    private struct State: Codable {
        var lastPlayedTrackByPlaylist: [String: String] = [:]
        /// Elapsed seek position (seconds) within the last-played track for a playlist slug — one
        /// value per slot, tied to whichever track `lastPlayedTrackByPlaylist` currently records
        /// for that slug (not a history of positions per track).
        var lastPlayedPositionByPlaylist: [String: Double] = [:]
        var lastActivePlaylistSlug: String?
        /// App-wide master volume trim (0.0–1.0), independent of per-playlist state. Defaults to
        /// 1.0 ("no attenuation") for a newly-installed app with no prior persisted state.
        var masterVolume: Double = 1.0

        init() {}

        /// Custom decoding: a property's `= default` initializer is NOT applied by Swift's
        /// synthesized `Decodable` for a missing key on a non-Optional type (only `Optional`
        /// properties get that treatment, via an implicit `decodeIfPresent`) — confirmed via a
        /// standalone script while adding `lastPlayedPositionByPlaylist` below (added 2026-08-11
        /// for player-state-003). Without this, decoding a `player-state.json` written before
        /// *any* non-Optional field here existed (e.g. before `masterVolume`, volume-control-001)
        /// throws and `load()`'s catch-all falls back to a fully-empty `State()` — silently
        /// discarding the last-played-track/last-active-playlist data too, not just defaulting
        /// the new field. Decoding every field via `decodeIfPresent ?? <default>` makes adding a
        /// field here backward-compatible going forward, and fixes that latent gap retroactively
        /// for existing installs.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastPlayedTrackByPlaylist = try container.decodeIfPresent(
                [String: String].self, forKey: .lastPlayedTrackByPlaylist) ?? [:]
            lastPlayedPositionByPlaylist = try container.decodeIfPresent(
                [String: Double].self, forKey: .lastPlayedPositionByPlaylist) ?? [:]
            lastActivePlaylistSlug = try container.decodeIfPresent(
                String.self, forKey: .lastActivePlaylistSlug)
            masterVolume = try container.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1.0
        }
    }

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("PlaylistBar", isDirectory: true)
            .appendingPathComponent("player-state.json")
    }

    private static func load() -> State {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    private static func save(_ state: State) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The last-played track's video id for a playlist, or `nil` if it's never been played
    /// (callers should default to the first track in that case).
    static func lastPlayedTrack(forPlaylistSlug slug: String) -> String? {
        load().lastPlayedTrackByPlaylist[slug]
    }

    /// Records `videoID` as the last-played track for `slug`. Call this on every track change:
    /// play, previous, next, reset, or clicking a track in the list.
    static func setLastPlayedTrack(_ videoID: String, forPlaylistSlug slug: String) {
        var state = load()
        state.lastPlayedTrackByPlaylist[slug] = videoID
        save(state)
    }

    /// The last-played track's saved seek position (seconds) for a playlist, or `nil` if never
    /// saved (callers should treat this as "start from 0:00").
    static func lastPlayedPosition(forPlaylistSlug slug: String) -> Double? {
        load().lastPlayedPositionByPlaylist[slug]
    }

    /// Records `position` as the last-played track's seek position for `slug`. It's the caller's
    /// responsibility to only save a position that corresponds to the track currently recorded by
    /// `setLastPlayedTrack` for this slug, so the two stay consistent.
    static func setLastPlayedPosition(_ position: Double, forPlaylistSlug slug: String) {
        var state = load()
        state.lastPlayedPositionByPlaylist[slug] = position
        save(state)
    }

    /// The slug of the playlist that was last active/selected, or `nil` on first-ever launch.
    static func lastActivePlaylistSlug() -> String? {
        load().lastActivePlaylistSlug
    }

    /// Records `slug` as the last active/selected playlist, so app launch can restore it.
    static func setLastActivePlaylist(slug: String) {
        var state = load()
        state.lastActivePlaylistSlug = slug
        save(state)
    }

    /// The persisted app-wide master volume trim, or 1.0 (no attenuation) if never set.
    static func masterVolume() -> Double {
        load().masterVolume
    }

    /// Records `volume` as the new master volume trim. Call this whenever the level changes.
    static func setMasterVolume(_ volume: Double) {
        var state = load()
        state.masterVolume = volume
        save(state)
    }
}
