import Foundation

/// One eligible video in the BGM pool: a long-form (15+ minute), non-members-only video from a
/// configured BGM channel — see `bgm-002`'s scan/filter and SPEC.md's "BGM channel playback".
/// Distinct from `CachedTrack` (`PlaylistCache.swift`) because a BGM track additionally tracks a
/// local listen count that must survive a rescan (see `BGMCacheStore.merge` below), which the 4
/// fixed playlists have no equivalent of.
struct BGMTrack: Codable, Equatable {
    let videoID: String
    let title: String
    /// Real duration in seconds, as reported by the channel scan — used for the 15-minute
    /// eligibility filter (`bgm-002`) and the listen-count threshold (`bgm-005`).
    let duration: Double
    var listenCount: Int = 0
    /// Same per-track normalization gain concept as `CachedTrack.normalizationGain` — `nil` until
    /// measured. Tracked here too (rather than a separate cache) so BGM videos get the same
    /// loudness normalization as regular playlist tracks — see SPEC.md's "BGM channel playback".
    var normalizationGain: Double? = nil
}

/// The pooled BGM cache: eligible videos across every configured channel (currently one — see
/// SPEC.md), deduped by video id. Deliberately doesn't record which channel a track came from —
/// the pool is a single shared selection space (fewest-listens-wins across all configured
/// channels combined, not one picker entry per channel), so per-track channel origin isn't
/// needed for anything this cache is used for.
///
/// One shared `lastScannedAt` covers the whole pool rather than tracking staleness per channel —
/// simplest option while there's only one configured channel; revisit (e.g. per-channel
/// timestamps) if per-channel staleness ever actually matters.
struct BGMPoolCache: Codable, Equatable {
    let tracks: [BGMTrack]
    let lastScannedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(lastScannedAt) > BGMCacheStore.staleAfter
    }
}

enum BGMCacheStore {
    static let staleAfter: TimeInterval = 24 * 60 * 60

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("PlaylistBar", isDirectory: true)
            .appendingPathComponent("bgm-pool.json")
    }

    private static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    static func load() -> BGMPoolCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BGMPoolCache.self, from: data)
    }

    static func save(_ cache: BGMPoolCache) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Merges a freshly-scanned set of eligible tracks into the existing pool by video id: a
    /// track still present keeps its existing `listenCount`/`normalizationGain`; a track no
    /// longer present (deleted, went members-only, fell under 15 minutes, channel removed it) is
    /// simply absent from the result; a newly-eligible track is added starting at 0 listens with
    /// no cached gain. Pure function — callers (`bgm-003`) are responsible for persisting the
    /// result.
    ///
    /// This is the deliberate deviation from `PlaylistCacheStore`'s full-replace-on-rescan
    /// behavior — see SPEC.md's "BGM channel playback": losing listen counts on every 24h refresh
    /// would defeat the feature.
    static func merge(freshlyScanned: [BGMTrack], into existing: [BGMTrack]) -> [BGMTrack] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.videoID, $0) })
        return freshlyScanned.map { fresh in
            guard let previous = existingByID[fresh.videoID] else { return fresh }
            var merged = fresh
            merged.listenCount = previous.listenCount
            merged.normalizationGain = previous.normalizationGain
            return merged
        }
    }

    /// Increments one track's local listen count and persists it — a no-op if there's no cache
    /// yet or the video isn't (or is no longer) in the pool.
    static func incrementListenCount(forVideoID videoID: String) {
        guard let cache = load(),
              let index = cache.tracks.firstIndex(where: { $0.videoID == videoID }) else {
            return
        }
        var tracks = cache.tracks
        tracks[index].listenCount += 1
        try? save(BGMPoolCache(tracks: tracks, lastScannedAt: cache.lastScannedAt))
    }

    /// Updates one track's cached normalization gain and persists it — mirrors
    /// `PlaylistCacheStore.setNormalizationGain(_:forVideoID:playlistSlug:)`.
    static func setNormalizationGain(_ gain: Double, forVideoID videoID: String) {
        guard let cache = load(),
              let index = cache.tracks.firstIndex(where: { $0.videoID == videoID }) else {
            return
        }
        var tracks = cache.tracks
        tracks[index].normalizationGain = gain
        try? save(BGMPoolCache(tracks: tracks, lastScannedAt: cache.lastScannedAt))
    }
}
