import Foundation

/// Scans a YouTube channel's `/videos` tab via `yt-dlp --flat-playlist` and filters down to
/// videos eligible for the BGM pool — see SPEC.md's "BGM channel playback". Distinct from
/// `PlaylistScanner` (which returns every track in a fixed playlist unfiltered, in order) because
/// a channel scan needs `duration`/`availability` filtering before anything is added to the pool.
enum BGMChannelScanner {
    enum ScanError: Error {
        case ytDlpNotFound
        case processFailed(exitCode: Int32, errorOutput: String)
        case invalidOutput
    }

    private struct FlatPlaylistEntry: Decodable {
        let id: String?
        let title: String?
        let duration: Double?
        let availability: String?
    }

    private struct FlatPlaylistResult: Decodable {
        let entries: [FlatPlaylistEntry]
    }

    /// 15 minutes, per SPEC.md's BGM eligibility filter.
    static let minimumDuration: Double = 15 * 60
    /// The `availability` value yt-dlp reports for members-only videos — confirmed live against
    /// the real configured channel during this feature's interview (see `bgm-002`'s issue notes).
    private static let membersOnlyAvailability = "subscriber_only"

    /// Scans `channelURL`'s `/videos` tab and returns only videos eligible for the BGM pool
    /// (`duration >= 900s`, not members-only), with fresh metadata and no listen count/gain yet —
    /// merging that in against the existing pool is `bgm-003`'s job, not this function's.
    static func scan(channelURL: String) throws -> [BGMTrack] {
        let videosURL = channelURL.hasSuffix("/videos") ? channelURL : channelURL + "/videos"

        let result: YtDlpRunner.Result
        do {
            result = try YtDlpRunner.run(arguments: ["--flat-playlist", "-J", videosURL])
        } catch YtDlpRunner.RunError.ytDlpNotFound {
            throw ScanError.ytDlpNotFound
        } catch YtDlpRunner.RunError.launchFailed(let underlying) {
            throw ScanError.processFailed(exitCode: -1, errorOutput: "\(underlying)")
        }

        guard result.exitCode == 0 else {
            throw ScanError.processFailed(exitCode: result.exitCode, errorOutput: result.errorOutput)
        }

        guard let data = result.output.data(using: .utf8) else {
            throw ScanError.invalidOutput
        }

        let decoded: FlatPlaylistResult
        do {
            decoded = try JSONDecoder().decode(FlatPlaylistResult.self, from: data)
        } catch {
            throw ScanError.invalidOutput
        }

        // Entries missing an id or a duration can't be evaluated against the eligibility filter,
        // so they're dropped rather than defaulted — same "drop, don't guess" approach
        // PlaylistScanner takes for a missing id. A missing `availability` means *not*
        // members-only (the common case — most videos report no availability restriction at all).
        return decoded.entries.compactMap { entry -> BGMTrack? in
            guard let id = entry.id, let duration = entry.duration else { return nil }
            guard duration >= minimumDuration else { return nil }
            guard entry.availability != membersOnlyAvailability else { return nil }
            return BGMTrack(videoID: id, title: entry.title ?? "(untitled)", duration: duration)
        }
    }
}
