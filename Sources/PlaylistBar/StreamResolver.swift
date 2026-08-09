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
    }

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

    /// Resolves a playable, audio-only direct stream URL for a YouTube video id. Stream URLs
    /// expire after a few hours, so this should be called close to when playback actually
    /// starts rather than resolved in bulk ahead of time.
    static func resolve(videoID: String) throws -> StreamResolution {
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
            result = try YtDlpRunner.run(arguments: [
                "-f", "bestaudio[ext=m4a]/bestaudio", "--print", "%(duration)s", "-g", watchURL,
            ])
        } catch YtDlpRunner.RunError.ytDlpNotFound {
            throw ResolutionError.ytDlpNotFound
        } catch YtDlpRunner.RunError.launchFailed(let underlying) {
            throw ResolutionError.processFailed(exitCode: -1, errorOutput: "\(underlying)")
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
