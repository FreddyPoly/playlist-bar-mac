import Foundation

/// The YouTube channel(s) BGM draws its pool from — see SPEC.md's "BGM channel playback". A list
/// (not a single fixed URL) so a second channel can be added later without a schema change, even
/// though only one is configured today; hardcoded in source, same as `FixedPlaylists.all` — no
/// in-app UI to edit it.
enum BGMChannels {
    static let all: [String] = [
        "https://www.youtube.com/channel/UC_LtBDXXXqQiIBNO2NwEOPQ"
    ]
}
