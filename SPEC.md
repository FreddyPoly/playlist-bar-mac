# Playlist Bar

A native macOS menu bar app for personal use that plays a fixed set of YouTube playlists as
background audio, with instant playlist switching and resume-where-you-left-off per playlist.

## Goal

Frederic listens to music via 4 fixed YouTube playlists and wants a native, always-accessible
Mac menu bar player for them — not a browser tab, not a web app. Core needs: fast switching
between playlists (some are 2000+ tracks), resuming each playlist where it was left off, and
basic transport controls, all running locally with no backend/account of any kind.

## Fixed playlists

- Rock3 — `https://www.youtube.com/playlist?list=PLfT09cdpUEa-Wsl0GD-_u3_Fk9TMCRBpk` (~2300 tracks)
- Drum'N'Bass — `https://www.youtube.com/playlist?list=PLfT09cdpUEa9guKpPtnJl7C2_b7xfFBTp` (~1700 tracks)
- Tranquille — `https://www.youtube.com/playlist?list=PLfT09cdpUEa_mq_VHWDKfi7HJghYL8zE4`
- Jazz — `https://www.youtube.com/playlist?list=PLfT09cdpUEa_inCg8U3kkghFzRWdFLawW`

All 4 are public playlists — no YouTube sign-in or cookies required to read or play them.
These 4 URLs are hardcoded; there is no UI to add/remove/edit playlists.

## Platform & stack

- **Native Swift/SwiftUI app**, built and run via Xcode. Menu bar presence via SwiftUI
  `MenuBarExtra` — no dock icon, no separate window to manage.
- Target machine is running macOS 26 (Tahoe), Xcode already installed — no legacy macOS
  compatibility constraints; modern APIs (`SMAppService`, `MenuBarExtra`, `MPNowPlayingInfoCenter`)
  are all available.
- Not distributed, not notarized/signed for Gatekeeper — built and run locally only. First run
  requires right-click > Open (or an Xcode run) to bypass Gatekeeper.
- Not a git repo (yet) — local project only at project creation time.

## Playback engine

- **yt-dlp** (installed by the user via Homebrew — `brew install yt-dlp`, not automated by the
  agent) extracts a direct, audio-only stream URL for a given video ID. That URL is played with
  native **AVPlayer** — no embedded browser, no WebView.
- Audio-only (`bestaudio`), not video: faster to resolve, less bandwidth, and more reliable
  playback than YouTube's adaptive video+audio DASH streams.
- Resolved stream URLs expire after a few hours, so they are **not** pre-resolved in bulk.
  Resolution happens:
  - immediately when a track starts playing (current track), and
  - in the background for the *next* track while the current one plays, so auto-advance is
    effectively gapless.
- yt-dlp is an unofficial, third-party tool: it breaks whenever YouTube changes internals, and
  extracting stream URLs this way sits in a legal gray area relative to YouTube's Terms of
  Service. Accepted tradeoff for personal/local use — see Security section.
- **ffmpeg** (installed by the user via Homebrew — `brew install ffmpeg`, not automated by the
  agent) measures each track's loudness for volume normalization — see "Volume & loudness
  normalization" below. Added 2026-08-09.

## Playlist data & caching

- Playlist contents (video ID + title, in playlist order) are fetched via
  `yt-dlp --flat-playlist` — no YouTube Data API key, no Google Cloud project.
- Fetched playlist listings are cached to disk at
  `~/Library/Application Support/PlaylistBar/` (one cache file per playlist), so switching
  playlists is instant and never blocks on a live scan.
- Cache refresh policy: a playlist's cache is treated as stale after **24 hours**. On first use
  needing a stale/missing cache, a full re-scan runs in the background; the UI keeps using the
  existing cached list (if any) until the refresh completes, then swaps in the updated list.
  No manual "refresh" affordance is required by spec, but may be added as a convenience.
- Playlist order is whatever `yt-dlp --flat-playlist` reports (the playlist's actual configured
  order on YouTube) — no shuffle, no reordering by the app.
- Each cached track also carries an optional measured loudness/gain value once analyzed (see
  "Volume & loudness normalization" below) — analyzed lazily, not part of the initial
  `--flat-playlist` scan, and persists in the same per-playlist cache file. Missing (not yet
  analyzed) is a valid, expected state for any track never played.

## Volume & loudness normalization

Two independent gain stages multiply together to produce the audio actually sent to `AVPlayer`:
a per-track **normalization gain** (automatic) and an app-wide **master trim** (manual, see UI
below). Added 2026-08-09 after real usage: some tracks in the playlists are noticeably louder
than others, which a single manual slider can't fix — riding it per track defeats the point of
background listening.

- **Analysis**: the first time a track is played, its loudness is measured via `ffmpeg`'s
  `loudnorm` filter in analysis-only mode (single read-through pass over the resolved audio
  stream, no re-encode, no file written to disk) — the same tool/technique behind ReplayGain-style
  and Apple Music "Sound Check" normalization elsewhere.
- **Cut-only, target -14 LUFS integrated** (matches Spotify/YouTube Music's own normalization
  target): a track measured louder than -14 LUFS gets a gain `< 1.0` to bring it down to that
  level; a track already quieter is left at gain `1.0` (unchanged). Tracks are never boosted above
  their original loudness — `AVPlayer.volume` is a 0.0–1.0 attenuator only, and amplifying beyond
  that would need a real gain stage with real clipping risk, which is out of scope here.
- **Caching**: once measured, a track's gain is cached permanently alongside it in the playlist
  cache (see "Playlist data & caching" above) — analysis never repeats for a track already
  measured, even across relaunches.
- **When analysis happens, relative to playback**:
  - For the *next* track during normal forward listening (auto-advance, or Next), analysis is
    folded into the existing next-track background preload — by the time playback reaches that
    track, its gain is already known, with no added delay.
  - For an out-of-order jump to an unanalyzed track (clicking a track in the list, Previous,
    switching playlists), playback **briefly waits** for analysis to complete before starting, so
    that first play is still correctly normalized.
  - That wait is **bounded by a timeout**: if analysis doesn't finish in time, or fails outright
    (unreachable stream, malformed audio), playback starts unnormalized (gain `1.0`) rather than
    hanging — consistent with this app's existing "never block indefinitely" behavior elsewhere
    (e.g. `TrackAvailabilityResolver`'s bounded skip-unavailable pass). Failure/timeout is *not*
    cached — the track is simply re-analyzed the next time it's played.
- **No proactive/background pre-warming** of whole playlists for now — analysis only ever happens
  in the two moments above (next-track preload, or an out-of-order play). A playlist you've never
  played through will sound inconsistent until you've heard each track at least once; acceptable
  starting tradeoff, revisit later if it's not.

## Local state (per playlist)

Stored locally (JSON, in the same Application Support directory), no database, no sync:

- Last-played track (video ID) per playlist — updated on every track change (play, prev, next,
  reset, or clicking a track in the list), so quitting/relaunching preserves exact position.
- Which playlist was last active (used to restore state on next launch).
- Master volume trim (app-wide, not per-playlist) — persists across quit/relaunch like the rest
  of this state. Added 2026-08-09. Per-track normalization gain is separate persisted state, kept
  in the playlist cache rather than here — see "Volume & loudness normalization" above.

## UI (menu bar dropdown)

- Menu bar item shows a small icon **plus the current track title** (truncated as needed).
- Dropdown contains:
  - Playlist selector (dropdown of the 4 fixed playlists by name).
  - Transport controls: **Previous / Play-Pause / Next / Reset**.
  - Volume slider — a **master trim**, attenuating this app's own audio output independently of
    the system/macOS volume (layered on top of it, doesn't touch system volume or other apps'
    audio). Added 2026-08-09: native macOS volume alone wasn't enough headroom for comfortable
    listening even at its lowest setting. Sits on top of the automatic per-track loudness
    normalization (see "Volume & loudness normalization" above) rather than replacing it — the
    slider controls overall level, normalization controls relative level between tracks. No
    numeric readout, matching the track list's existing minimalism.
  - Track list: current track, up to 5 previous and up to 5 next (by playlist index — not play
    history), each an entry that starts playback immediately when clicked. Fewer than 5 are
    shown near either end of the playlist (no wrapping *in the list display*, see below).
  - No duration display, no seek/progress bar — just title + play/pause state.
  - Loading/buffering feedback — a visible state (not just a static Play/Pause icon) whenever
    audio isn't actually flowing but the app is working on it: switching playlists (cache scan in
    progress), resolving a fresh track's stream, recovering from a mid-stream stall, or waiting on
    an out-of-order track's loudness analysis (see "Volume & loudness normalization" above; bounded
    by the same timeout, so this state can't hang indefinitely). Added 2026-08-09: without this, a
    slow network stall looks identical to a frozen/broken app (see playback-engine-005's
    investigation). Applies everywhere a wait can happen, not just the stalled-stream case.
  - Standard extras: "Launch at Login" toggle, Quit.

## Behavior rules

- **Switching playlists**: loads instantly from cache, resumes the saved last-played track for
  that playlist (or track 1 if never played before), and starts playing immediately.
- **Previous / Next**: step by playlist index. At either end they **wrap around** (Previous on
  track 1 → last track; Next on the last track, including auto-advance at end of playlist → track
  1), so a playlist loops continuously.
- **Reset**: jumps to track 1 of the current playlist and plays it; this becomes the new saved
  position.
- **Auto-advance**: when a track finishes, automatically plays the next track (same wrap-around
  rule).
- **Unavailable tracks** (deleted/private/region-locked): automatically skipped on play or
  auto-advance; playback moves to the next track without stopping. (Track list display for a
  known-unavailable track may be visually de-emphasized — implementation detail, not a hard
  requirement.)
- **Clicking a track** in the previous/next list jumps directly to it and plays immediately,
  updating the saved position.
- Only one playlist plays at a time; switching stops whatever was previously playing.

## Startup / Login item

- Toggle in the app to enable/disable "Launch at Login" (via `SMAppService`).
- When launched at login, the app opens **idle/paused** — it restores the last active playlist
  and track selection but does **not** auto-play. Avoids music starting unexpectedly on boot.

## Native macOS integration

- **Now Playing** integration (`MPNowPlayingInfoCenter`): current track title and playlist name
  appear in macOS Control Center's Now Playing widget and the lock screen.
- **Media keys**: F7/F8/F9 (previous/play-pause/next) control playback system-wide, even when the
  menu bar dropdown is closed.

## Explicitly out of scope

- No support for playlists beyond the 4 fixed ones; no add/remove/reorder UI.
- No shuffle mode, no repeat-single-track mode (only whole-playlist looping via wrap-around).
- No duration/seek bar.
- No account/sign-in of any kind.
- No sync across machines — this is single-Mac, local-only.
- No packaging/notarization/distribution — local build and run only.

## Security

Low risk, small surface:

- **No authentication, no accounts, no OAuth** — all 4 playlists are public; nothing in the app
  ever touches Frederic's YouTube account or credentials.
- **No secrets or API keys** — the yt-dlp approach was specifically chosen to avoid needing a
  YouTube Data API key or any Google Cloud credential.
- **No untrusted user input** — the only external data is public YouTube playlist metadata
  (video IDs/titles) and resolved stream URLs, both fetched read-only via yt-dlp. Titles are
  rendered as plain text in SwiftUI views (no HTML/JS execution), so there's no injection surface
  from playlist content.
- **Local data sensitivity**: cached playlist listings and last-played-track state are stored
  unencrypted under `~/Library/Application Support/PlaylistBar/`. This is not sensitive data
  (just video IDs/titles of playlists Frederic already plays), so no encryption/Keychain use is
  warranted.
- **Supply chain**: yt-dlp and ffmpeg are both installed by the user directly via Homebrew (not
  auto-downloaded or auto-updated by the app), keeping binary installation under the user's
  explicit control. The app only ever shells out to the already-installed binaries on PATH.
- **ffmpeg invocation** (loudness analysis): same trust boundary as the existing yt-dlp usage —
  the only input is the already-resolved stream URL for a public YouTube video the app itself
  just fetched, no additional untrusted input. Invoked with an argument array (no shell
  string-interpolation), the same convention `YtDlpRunner` already uses, to avoid any command-
  injection surface even though the current input isn't attacker-controlled.
- **Known accepted risk (not a security vulnerability, but worth documenting)**: extracting
  playable stream URLs via yt-dlp is against YouTube's Terms of Service and is inherently fragile
  — YouTube changes can break yt-dlp's extractors at any time, requiring `brew upgrade yt-dlp`.
  Acceptable tradeoff for a personal, local-only tool; would need to be revisited if this were
  ever distributed to other users.

## Open questions

None outstanding — all decisions above were confirmed during the interview. Implementation-level
details not covered here (e.g. exact JSON cache schema, incremental vs. bulk flat-playlist
scanning, menu bar marquee text behavior) are left to the implementation phase.
