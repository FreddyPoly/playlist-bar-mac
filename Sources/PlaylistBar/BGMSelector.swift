import Foundation

/// Picks the next BGM video to play: whichever qualifying video has the fewest local listens
/// wins, with a uniform-random pick breaking ties — see SPEC.md's "BGM channel playback". Pure
/// function, mirroring this codebase's convention of isolating selection logic as directly
/// testable helpers (e.g. `TrackAvailabilityResolver`); doesn't touch listen counts or
/// persistence itself (see `bgm-005`/`bgm-001`).
enum BGMSelector {
    /// Selects from `pool`, excluding `excludingVideoID` (typically the video that was just
    /// playing, so it can't repeat back-to-back) — unless excluding it would leave nothing to
    /// pick from, in which case it becomes eligible again. Returns `nil` only for a genuinely
    /// empty pool, distinct from the one-video-excluding-current case.
    static func selectNext(from pool: [BGMTrack], excluding excludingVideoID: String?) -> BGMTrack? {
        guard !pool.isEmpty else { return nil }

        var candidates = pool
        if let excludingVideoID {
            let withoutExcluded = pool.filter { $0.videoID != excludingVideoID }
            if !withoutExcluded.isEmpty {
                candidates = withoutExcluded
            }
        }

        guard let minListenCount = candidates.map(\.listenCount).min() else { return nil }
        let tiedForFewest = candidates.filter { $0.listenCount == minListenCount }
        return tiedForFewest.randomElement()
    }
}
