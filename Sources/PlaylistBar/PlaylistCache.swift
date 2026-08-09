import Foundation

/// A single track as scanned from a YouTube playlist.
struct CachedTrack: Codable, Equatable {
    let videoID: String
    let title: String
    /// Measured per-track normalization gain (0.0–1.0, cut-only toward `LoudnessAnalyzer`'s
    /// target LUFS), or `nil` if never analyzed — the expected state for any track never played.
    /// A cache file written before this field existed simply decodes it as `nil` (Swift's
    /// synthesized `Decodable` treats an `Optional` stored property as an optional coding key).
    var normalizationGain: Double? = nil
}

/// The cached contents of one playlist: its track order plus when it was last scanned.
struct PlaylistCache: Codable, Equatable {
    let tracks: [CachedTrack]
    let lastScannedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(lastScannedAt) > PlaylistCacheStore.staleAfter
    }
}

enum PlaylistCacheStore {
    static let staleAfter: TimeInterval = 24 * 60 * 60

    private static var directoryURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("PlaylistBar", isDirectory: true)
    }

    private static func fileURL(forPlaylistSlug slug: String) -> URL {
        directoryURL.appendingPathComponent("\(slug).json")
    }

    private static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
    }

    static func load(playlistSlug slug: String) -> PlaylistCache? {
        let url = fileURL(forPlaylistSlug: slug)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PlaylistCache.self, from: data)
    }

    static func save(_ cache: PlaylistCache, playlistSlug slug: String) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: fileURL(forPlaylistSlug: slug), options: .atomic)
    }

    /// Updates just one track's cached normalization gain (see `LoudnessAnalyzer`) and persists
    /// it, without a full playlist re-scan. A no-op if the playlist has no cache yet, or doesn't
    /// contain a track with this video id (e.g. a superseded/stale cache).
    static func setNormalizationGain(_ gain: Double, forVideoID videoID: String, playlistSlug slug: String) {
        guard let cache = load(playlistSlug: slug),
              let index = cache.tracks.firstIndex(where: { $0.videoID == videoID }) else {
            return
        }
        var tracks = cache.tracks
        tracks[index].normalizationGain = gain
        let updatedCache = PlaylistCache(tracks: tracks, lastScannedAt: cache.lastScannedAt)
        try? save(updatedCache, playlistSlug: slug)
    }
}
