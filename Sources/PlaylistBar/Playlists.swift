import Foundation

/// One of the app's 4 fixed playlists (see SPEC.md). Not user-editable — there is no UI to
/// add/remove/reorder playlists.
struct Playlist: Identifiable, Equatable, Hashable {
    let slug: String
    let name: String
    let url: String

    var id: String { slug }
}

enum FixedPlaylists {
    static let all: [Playlist] = [
        Playlist(
            slug: "rock3",
            name: "Rock3",
            url: "https://www.youtube.com/playlist?list=PLfT09cdpUEa-Wsl0GD-_u3_Fk9TMCRBpk"
        ),
        Playlist(
            slug: "drum-n-bass",
            name: "Drum'N'Bass",
            url: "https://www.youtube.com/playlist?list=PLfT09cdpUEa9guKpPtnJl7C2_b7xfFBTp"
        ),
        Playlist(
            slug: "tranquille",
            name: "Tranquille",
            url: "https://www.youtube.com/playlist?list=PLfT09cdpUEa_mq_VHWDKfi7HJghYL8zE4"
        ),
        Playlist(
            slug: "jazz",
            name: "Jazz",
            url: "https://www.youtube.com/playlist?list=PLfT09cdpUEa_inCg8U3kkghFzRWdFLawW"
        ),
    ]
}
