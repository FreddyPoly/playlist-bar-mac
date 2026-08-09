import Foundation

/// Scans a YouTube playlist's contents via `yt-dlp --flat-playlist`, without downloading or
/// resolving playable streams for any track.
enum PlaylistScanner {
    enum ScanError: Error {
        case ytDlpNotFound
        case processFailed(exitCode: Int32, errorOutput: String)
        case invalidOutput
    }

    private struct FlatPlaylistEntry: Decodable {
        let id: String?
        let title: String?
    }

    private struct FlatPlaylistResult: Decodable {
        let entries: [FlatPlaylistEntry]
    }

    /// Returns the playlist's tracks in its actual configured order. `playlistURL` is expected
    /// to be one of the app's 4 fixed playlist URLs — not arbitrary/user-entered input.
    static func scan(playlistURL: String) throws -> [CachedTrack] {
        let result: YtDlpRunner.Result
        do {
            result = try YtDlpRunner.run(arguments: ["--flat-playlist", "-J", playlistURL])
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

        // Entries missing an id (e.g. some unavailable-video placeholders) are dropped here;
        // a missing title falls back to a placeholder rather than dropping the track, since we
        // can still play it by id. Order is preserved as yt-dlp reports it.
        return decoded.entries.compactMap { entry in
            guard let id = entry.id else { return nil }
            return CachedTrack(videoID: id, title: entry.title ?? "(untitled)")
        }
    }
}
