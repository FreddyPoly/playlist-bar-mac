import Foundation

enum PlayableResolution: Equatable {
    case playable(index: Int, url: URL, duration: Double?)
    /// Every track in the playlist was tried once and none resolved as playable.
    case noneAvailable
}

/// Finds the next actually-playable track starting from a given index, skipping over
/// unavailable ones (deleted/private/region-locked — see StreamResolver) automatically.
enum TrackAvailabilityResolver {
    /// Tries `tracks[startIndex]`, then each subsequent track in playlist order (wrapping
    /// around at the end), until one resolves successfully or every track has been tried
    /// exactly once — bounding this to at most `tracks.count` attempts guarantees it can never
    /// loop forever, even if every track in the playlist is unavailable.
    ///
    /// Only `StreamResolver.ResolutionError.ytDlpNotFound` is treated as systemic — yt-dlp being
    /// missing would fail identically for every remaining track, so it's thrown immediately
    /// instead of retried `tracks.count` times. Every other resolution failure (a malformed
    /// response, no matching audio format for that specific video, etc.) is about that one
    /// track, not the playlist as a whole, so — like `.unavailable` — it's treated as "skip this
    /// one and keep going" rather than aborting playback entirely.
    static func resolveNextPlayable(
        tracks: [CachedTrack],
        startIndex: Int
    ) async throws -> PlayableResolution {
        guard !tracks.isEmpty else { return .noneAvailable }

        var index = startIndex
        for _ in 0..<tracks.count {
            let track = tracks[index]
            do {
                let result = try await Task.detached(priority: .utility) {
                    try StreamResolver.resolve(videoID: track.videoID)
                }.value

                switch result {
                case .available(let url, let duration):
                    return .playable(index: index, url: url, duration: duration)
                case .unavailable:
                    index = (index + 1) % tracks.count
                }
            } catch StreamResolver.ResolutionError.ytDlpNotFound {
                throw StreamResolver.ResolutionError.ytDlpNotFound
            } catch {
                index = (index + 1) % tracks.count
            }
        }

        return .noneAvailable
    }
}
