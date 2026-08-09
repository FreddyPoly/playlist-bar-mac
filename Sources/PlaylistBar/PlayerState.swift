import Foundation

/// Local, per-playlist playback position — separate from `PlaylistCacheStore`'s track-list
/// cache, since this changes on every track change rather than every 24h scan.
enum PlayerStateStore {
    private struct State: Codable {
        var lastPlayedTrackByPlaylist: [String: String] = [:]
        var lastActivePlaylistSlug: String?
        /// App-wide master volume trim (0.0–1.0), independent of per-playlist state. Defaults to
        /// 1.0 ("no attenuation") for a newly-installed app with no prior persisted state.
        var masterVolume: Double = 1.0
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
