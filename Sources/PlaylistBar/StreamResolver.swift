import Foundation

enum StreamResolution: Equatable {
    /// `duration` is the video's real duration (seconds) per yt-dlp's own metadata — `nil` if
    /// yt-dlp didn't report one. Not to be confused with `AVURLAsset`'s own duration estimate:
    /// for a progressively-streamed, "not optimized" (moov-atom-at-end) M4A — which is how these
    /// resolved YouTube audio streams are actually served — `AVFoundation` computes a duration
    /// estimate that can be wildly wrong (confirmed ~2x too long on a real track, most likely a
    /// channel-count/bitrate misdetection) before it's actually read enough of the file to know
    /// better, and forcing precise timing (`AVURLAssetPreferPreciseDurationAndTimingKey`) doesn't
    /// fix it. This `duration` is yt-dlp's own reported value instead, used by `AudioPlayer` as a
    /// trustworthy fallback for detecting a track's real end. See playback-engine-005.
    case available(url: URL, duration: Double?)
    case unavailable
}

enum StreamResolver {
    enum ResolutionError: Error {
        case ytDlpNotFound
        case processFailed(exitCode: Int32, errorOutput: String)
        case invalidOutput
        /// `resolveTimeout` elapsed with no result — every caller (`TrackAvailabilityResolver`,
        /// `NextTrackPreloader`, `PlaybackController.playBGM`) already treats any non-
        /// `ytDlpNotFound` error the same as an unavailable track (skip and move on), so this
        /// needs no special handling at those call sites — see SPEC.md's "Resolution and
        /// buffering timeouts".
        case timedOut
    }

    /// How long a single video's stream resolution is allowed to take before giving up — bounds
    /// what was previously an unbounded `yt-dlp -g` call that could leave the UI on a permanent
    /// loading spinner if it ever stalled. A single-video resolve normally takes 1-3s; 10s leaves
    /// real margin for network variance. See SPEC.md's "Resolution and buffering timeouts".
    static let resolveTimeout: Duration = .seconds(10)

    /// yt-dlp error messages that indicate the video is genuinely gone (deleted/private/
    /// region-locked/age-gated) rather than some other failure (network hiccup, rate limiting,
    /// unexpected yt-dlp error). Matched case-insensitively as substrings, since yt-dlp doesn't
    /// expose this as a structured error code. Best-effort — may need extending as real-world
    /// cases turn up that aren't covered here.
    private static let unavailabilityMarkers = [
        "video unavailable",
        "private video",
        "this video is unavailable",
        "this video has been removed",
        "this video is no longer available",
        "content isn't available",
        "content is not available",
        "not available in your country",
        "sign in to confirm your age",
        "members-only content",
    ]

    /// Resolves a playable direct stream URL for a YouTube video id. Stream URLs expire after a
    /// few hours, so this should be called close to when playback actually starts rather than
    /// resolved in bulk ahead of time.
    ///
    /// - Parameter preferProgressive: When `true`, resolves YouTube's legacy progressive
    ///   (audio+video combined, faststart/`moov`-at-front) format instead of the default
    ///   audio-only DASH format. Used by BGM only (see SPEC.md's "BGM channel playback" — "Startup
    ///   latency for long videos"): DASH audio-only streams are `moov`-atom-at-end, and
    ///   `AVPlayer`'s time-to-ready-to-play for that shape scales with file size/length badly
    ///   enough for BGM's long (15 min–1 hr+) videos to look frozen for minutes. The 4 fixed
    ///   playlists' short tracks have never shown this, so they keep the efficient audio-only
    ///   default.
    static func resolve(videoID: String, preferProgressive: Bool = false) throws -> StreamResolution {
        let watchURL = "https://www.youtube.com/watch?v=\(videoID)"

        let result: YtDlpRunner.Result
        do {
            // Prefer M4A/AAC over yt-dlp's default "bestaudio" pick: YouTube's highest-bitrate
            // audio-only stream is usually WebM/Opus, which AVFoundation doesn't natively
            // decode (playback silently never becomes ready). M4A/AAC is available for
            // virtually every YouTube video and plays natively. Falls back to plain bestaudio
            // for the rare video with no M4A track at all. `--print "%(duration)s"` piggybacks
            // the real duration onto the same call (see `StreamResolution.available`'s doc
            // comment) — printed before `-g`'s URL line, no extra yt-dlp invocation needed.
            let formatSelector = preferProgressive
                ? "best[acodec!=none][vcodec!=none]"
                : "bestaudio[ext=m4a]/bestaudio"
            result = try YtDlpRunner.run(
                arguments: ["-f", formatSelector, "--print", "%(duration)s", "-g", watchURL],
                timeout: Self.resolveTimeout
            )
        } catch YtDlpRunner.RunError.ytDlpNotFound {
            throw ResolutionError.ytDlpNotFound
        } catch YtDlpRunner.RunError.launchFailed(let underlying) {
            throw ResolutionError.processFailed(exitCode: -1, errorOutput: "\(underlying)")
        } catch YtDlpRunner.RunError.timedOut {
            throw ResolutionError.timedOut
        }

        guard result.exitCode == 0 else {
            let lowered = result.errorOutput.lowercased()
            if unavailabilityMarkers.contains(where: { lowered.contains($0) }) {
                return .unavailable
            }
            throw ResolutionError.processFailed(exitCode: result.exitCode, errorOutput: result.errorOutput)
        }

        var lines = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { throw ResolutionError.invalidOutput }

        let urlLine = lines.removeLast()
        guard !urlLine.isEmpty, let url = URL(string: urlLine) else {
            throw ResolutionError.invalidOutput
        }
        let duration = lines.last.flatMap(Double.init)

        return .available(url: url, duration: duration)
    }
}
