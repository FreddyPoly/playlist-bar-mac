# Playlist Bar

A native macOS menu bar app for personal use that plays a fixed set of YouTube playlists as
background audio, with instant playlist switching and resume-where-you-left-off per playlist.

## Goal

Frederic listens to music via 4 fixed YouTube playlists and wants a native, always-accessible
Mac menu bar player for them — not a browser tab, not a web app. Core needs: fast switching
between playlists (some are 2000+ tracks), resuming each playlist where it was left off, and
basic transport controls, all running locally with no backend/account of any kind.

A 5th entry, **BGM**, was added 2026-08-10 (see "BGM channel playback" below) — instead of one
fixed ordered playlist, it plays random long-form videos from a pool of YouTube channels,
weighted toward whichever video has been listened to least locally.

## Fixed playlists

- Rock3 — `https://www.youtube.com/playlist?list=PLfT09cdpUEa-Wsl0GD-_u3_Fk9TMCRBpk` (~2300 tracks)
- Drum'N'Bass — `https://www.youtube.com/playlist?list=PLfT09cdpUEa9guKpPtnJl7C2_b7xfFBTp` (~1700 tracks)
- Tranquille — `https://www.youtube.com/playlist?list=PLfT09cdpUEa_mq_VHWDKfi7HJghYL8zE4`
- Jazz — `https://www.youtube.com/playlist?list=PLfT09cdpUEa_inCg8U3kkghFzRWdFLawW`

All 4 are public playlists — no YouTube sign-in or cookies required to read or play them.
These 4 URLs are hardcoded; there is no UI to add/remove/edit playlists.

The playlist picker has a 5th entry, **BGM**, which is not one of these 4 ordered playlists —
see "BGM channel playback" below.

## BGM channel playback

Added 2026-08-10. Unlike the 4 fixed playlists (one ordered list each), BGM draws from a **pool
of one or more YouTube channels** — currently just one:

- Deep Emotion BGM — `https://www.youtube.com/channel/UC_LtBDXXXqQiIBNO2NwEOPQ` (real check via
  `yt-dlp --flat-playlist` on its `/videos` tab: 177 videos total, 106 qualify under the filter
  below)

Built so a second channel can later be added into the **same shared pool** (one "BGM" entry
drawing from all configured channels combined, deduped by video id) rather than becoming its own
separate picker entry — a deliberate choice over one-picker-entry-per-channel.

- **Sourcing**: each channel's `/videos` tab is scanned via `yt-dlp --flat-playlist`, same
  mechanism as the 4 fixed playlists (see "Playlist data & caching"). Confirmed live: this scan
  already returns `duration` and an `availability` field per entry — no extra per-video calls
  needed to filter.
- **Filtering**: a video qualifies for the pool if `duration >= 900` seconds (15 minutes) and
  `availability != "subscriber_only"` (excludes members-only videos — this is the real marker
  yt-dlp reports for them).
- **Selection algorithm**: picking a video = whichever qualifying video has the **fewest local
  listens** wins; a uniform-random pick breaks ties among videos sharing the minimum count. The
  video that was just playing is excluded from that immediate next pick even if it's still tied
  for fewest listens (so it can't repeat back-to-back) — falling back to including it only if
  excluding it would leave the pool empty.
- **What counts as a "listen"**: a qualifying video's local listen count increments once
  continuous playback of it passes `min(30s, 20% of its duration)` — long enough that an
  accidental skip doesn't inflate the count, short enough not to require finishing a 20-minute
  track. Local to this player only; nothing is reported to YouTube or anywhere else. Measured as
  **elapsed playback time since this listen started**, not absolute position in the track — so
  resuming a BGM video mid-way via saved-position resume (see "Local state (per playlist)" below)
  still requires listening `min(30s, 20%)` further before it counts, the same as starting fresh;
  it is not instantly credited just because the resumed position happens to already be past that
  threshold.
- **Caching & merge**: channel scans are cached and refreshed on the same 24h-staleness pattern
  as the 4 fixed playlists (see "Playlist data & caching"), but — unlike that cache, which fully
  replaces its track list on every rescan — a BGM rescan **merges** by video id: local listen
  counts (and normalization gain) for videos still present after a rescan are preserved, not
  reset. This is a deliberate deviation from the fixed-playlist cache behavior, since losing
  listen counts on every 24h refresh would defeat the feature.
- **Navigation is different from the 4 fixed playlists** (no fixed order, so index-based
  wrap-around doesn't apply) — see "Behavior rules" below.
- **Master volume trim applies to BGM exactly as it does to regular playlist tracks — per-track
  loudness normalization does not** (revised 2026-08-10, see "Startup latency for long videos"
  below for why). BGM videos always play at normalization gain `1.0`; only the manual master trim
  attenuates them.
- **Stream resolution is special-cased for BGM** (revised 2026-08-10): BGM resolves its playable
  stream via yt-dlp's `best[acodec!=none][vcodec!=none]` selector — YouTube's legacy progressive
  (audio+video combined, faststart) format — instead of the `bestaudio[ext=m4a]/bestaudio`
  audio-only format the 4 fixed playlists use. The bundled video track is downloaded but never
  decoded (disabled on the loaded player item — there's no video surface in this app regardless).
  If no progressive format exists for a given video (rare), it's treated as unavailable for that
  pick, same as a deleted/private/region-locked video — skipped in favor of another selection via
  the existing retry loop, not a new failure path.

### Startup latency for long videos (found during BGM QC, fixed 2026-08-10)

YouTube's audio-only DASH formats (itags 139/249/140/251) are served with the MP4 `moov` atom
positioned at the *end* of the file rather than the front ("faststart"). `AVFoundation` has to
effectively reach near the end of the file before it can begin decoding anything. For the 4 fixed
playlists' short (few-minute) tracks this cost was never noticeable. BGM's videos are the first
content in this app with no upper length bound (confirmed live: a real ~59-minute pool video took
several minutes of dead-air, spinner-only wait before audio started) — the delay scales with file
size/length, and BGM is the only place in the app that plays anything long enough to expose it.

Confirmed via live investigation (system log + `nettop`) that this is **not** a bug in this app's
own orchestration code — `playBGM`'s loudness-analysis timeout, stream resolution, and
`player.load`/`player.play` calls all complete correctly within seconds; `AVPlayer` itself was
just slow to become ready-to-play for that specific stream shape.

**Fix**: BGM resolves via a progressive (faststart) format instead of audio-only DASH — see above.
This eliminates the delay regardless of video length, at the cost of downloading (not decoding)
unneeded video data — an accepted tradeoff given this is a local, unmetered-connection tool.
**Loudness normalization was dropped for BGM as a consequence**, not decided independently: the
per-track analysis pass would now also need to skip/ignore the newly-present video stream, and for
an hour-long ambient track the `ffmpeg` analysis itself could take many minutes of real time for
a value whose benefit (precise volume-matching for long-form ambient content) was judged not worth
that ongoing cost once startup speed no longer depended on it.

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
- **Does not apply to BGM** (revised 2026-08-10) — BGM always plays at normalization gain `1.0`.
  See "BGM channel playback"'s "Startup latency for long videos" for why this was dropped
  specifically for BGM after initially being designed to cover it too.

## Local state (per playlist)

Stored locally (JSON, in the same Application Support directory), no database, no sync:

- Last-played track (video ID) per playlist — updated on every track change (play, prev, next,
  reset, or clicking a track in the list), so quitting/relaunching preserves exact position.
- **Last-played timestamp (seek position) per playlist** (added 2026-08-11): alongside the
  video ID above, the exact elapsed position (seconds) within that track is also saved — one
  value per playlist slot, tied to whichever track is currently the "last played" one (not a
  history of positions per track; switching to a different track discards the old track's saved
  position, same single-value-per-slug model as the video ID itself). Applies to all 5 playlist
  slots: the 4 fixed playlists and BGM.
  - **Write cadence**: a periodic save every ~5s while playing, plus event-driven saves on pause,
    switching away from the playlist, and track change — mirrors this app's existing 1Hz-timer
    pattern (`BGMListenTracker`). No flush-on-quit hook (`Quit` calls
    `NSApplication.terminate(nil)` directly, unchanged) — a clean Quit has the same up-to-~5s
    loss window as a crash or force-quit; deliberately kept simple rather than adding an
    `applicationWillTerminate` hook for this.
  - **When it's applied**: any time that saved track is (re)loaded — a cold-start relaunch and a
    live switch-away-and-back within the same run both seek to the saved position, via the same
    `play()`/restore path. Not relaunch-only.
  - **Near-end clamp**: if the saved position is within ~5s of the track's known duration (the
    same trusted yt-dlp duration `AudioPlayer`'s end-of-track watchdog already uses — see
    "Playback engine" below), resume clamps to 0:00 instead of replaying a few seconds and
    instantly auto-advancing, which would read as a bug.
  - **No visible seek/scrub UI** — this is background-only resume; the dropdown still shows no
    duration or progress bar (see "UI (menu bar dropdown)" below), unchanged.
- Which playlist was last active (used to restore state on next launch).
- Master volume trim (app-wide, not per-playlist) — persists across quit/relaunch like the rest
  of this state. Added 2026-08-09. Per-track normalization gain is separate persisted state, kept
  in the playlist cache rather than here — see "Volume & loudness normalization" above.
- **BGM**, added 2026-08-10: last-played video (id) is persisted the same way as the 4 fixed
  playlists' last-played track, so relaunch restores and displays it (without auto-playing — see
  "Startup / Login item") rather than picking fresh. As of 2026-08-11 its saved position (see
  above) is restored the same way, too — but BGM's listen-count threshold is measured relative to
  elapsed time since the resume, not absolute position (see "BGM channel playback" — "What counts
  as a listen"), so resuming near the end of a long video doesn't instantly credit a listen. Each
  pooled video's local listen count is also persisted (alongside its cached channel-scan entry —
  see "BGM channel playback"). The **session Previous history** (the list of videos actually
  played this run, used to walk backward — see "Behavior rules") is **not** persisted; it starts
  empty on every launch.

## UI (menu bar dropdown)

- Menu bar item shows **icon-only** (no track-title text) — changed 2026-08-12, decided via
  `/interview` after the user found the icon getting hidden by macOS menu bar overflow (too many
  status items for the available width; confirmed via `ps` that the app itself was still running,
  not crashed). A variable-width text label was judged the likely reason PlaylistBar's own item
  was the one getting squeezed out, so it was dropped in favor of a minimal, fixed-width icon.
  Trade-off accepted: no more always-visible "what's playing" text — the track title is
  dropdown-only now. The icon glyph itself swaps between playing/paused state (e.g. a filled vs.
  outline/paused variant), so at least play/pause status is visible without opening the dropdown.
  A hover tooltip (SwiftUI `.help()`) with the track title was tried as a zero-width way to keep
  some of that glance info, but **doesn't actually work**: `.help()` doesn't render on
  `MenuBarExtra` status items (same underlying AppKit-hosting quirk as the pre-existing
  Label-text-collapse issue — see `PlaylistBarApp.swift`). Fixing that would require replacing
  `MenuBarExtra` with a hand-rolled `NSStatusItem`; judged not worth it for a tooltip (user
  decision via `/interview`, 2026-08-12) — dropped instead of pursued.
  Immediate workaround for when the icon is hidden entirely: macOS Control Center's Now Playing
  widget already works via this app's existing `MPNowPlayingInfoCenter`/media-key integration
  (play/pause/skip), independent of whether PlaylistBar's own menu bar icon is visible.
- Dropdown contains:
  - Playlist selector (dropdown of the 4 fixed playlists plus **BGM**, by name).
  - Transport controls: **Previous / Play-Pause / Next / Reset** — same buttons for BGM, but see
    "Behavior rules" below for how their meaning differs there.
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
    **BGM's list is different** (added 2026-08-10, decided after discussion — a full catalog of
    all ~106 qualifying videos wouldn't help pick one, and "5 next" is meaningless when the next
    pick isn't determined yet): shows up to 5 **previously-played videos this session** (real
    history, not catalog order — click any to jump back to it, same interaction as the regular
    list) plus the current track highlighted. No "next" slot at all. Each visible BGM entry
    (history + current) shows its local listen count next to the title, so the
    fewest-listens-wins selection is visible rather than a black box.
  - No duration display, no seek/progress bar — just title + play/pause state. (Resuming at a
    saved position, added 2026-08-11, is background-only — see "Local state (per playlist)" — and
    doesn't change this: still no visible scrubber or elapsed-time readout.)
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
  that playlist (or track 1 if never played before) **at its saved position** (or 0:00 if never
  played, or if the saved position was within ~5s of the end — see "Local state (per playlist)"),
  and starts playing immediately.
- **Previous / Next**: step by playlist index. At either end they **wrap around** (Previous on
  track 1 → last track; Next on the last track, including auto-advance at end of playlist → track
  1), so a playlist loops continuously. Each lands at 0:00 (a fresh track), not a saved position.
- **Reset**: jumps to track 1 of the current playlist and plays it from 0:00; this becomes the new
  saved position (0:00).
- **Auto-advance**: when a track finishes, automatically plays the next track (same wrap-around
  rule).
- **Unavailable tracks** (deleted/private/region-locked): automatically skipped on play or
  auto-advance; playback moves to the next track without stopping. (Track list display for a
  known-unavailable track may be visually de-emphasized — implementation detail, not a hard
  requirement.)
- **Clicking a track** in the previous/next list jumps directly to it and plays immediately,
  updating the saved position.
- Only one playlist plays at a time; switching stops whatever was previously playing.
- **BGM's transport rules are different** (added 2026-08-10), since there's no fixed track order
  to step through:
  - **Next** (button, or auto-advance when a video finishes): picks a new video via BGM's
    fewest-listens/random-tiebreak selection (see "BGM channel playback"), appends it to the
    session history, and starts it.
  - **Previous**: walks backward through the session's actual play history (like a browser back
    button) and plays that video — a no-op if there's no earlier history yet (e.g. right after
    switching to BGM). Clicking a history entry in the track list behaves the same as navigating
    back to that point.
  - **Reset**: restarts the *current* video from 0:00 — it does **not** pick a new video (Next
    already covers that) and does not affect history.
  - If Previous has been used to step back through history and **Next** is then pressed, it
    always picks a fresh weighted-random video rather than redoing forward through history —
    anything "ahead" in the history at that point is discarded, not replayed.
  - Unavailable-video auto-skip still applies the same as the 4 fixed playlists.

## Startup / Login item

- Toggle in the app to enable/disable "Launch at Login" (via `SMAppService`).
- When launched at login, the app opens **idle/paused** — it restores the last active playlist
  and track selection but does **not** auto-play. Avoids music starting unexpectedly on boot. The
  first Play press after that restore resumes at the saved position (see "Local state (per
  playlist)"), not 0:00.

## Native macOS integration

- **Now Playing** integration (`MPNowPlayingInfoCenter`): current track title and playlist name
  appear in macOS Control Center's Now Playing widget and the lock screen.
- **Media keys**: F7/F8/F9 (previous/play-pause/next) control playback system-wide, even when the
  menu bar dropdown is closed.

## Automated QC harness

Added 2026-08-13 to eliminate manual guided QC as the *first* pass — repeated rounds of clicking
the menu bar and reporting what's seen had caused false positives from stale app instances and
"still empty" debugging loops that were really just testing an old build. `Scripts/qc.sh` now runs
first (wired into the `qc` skill); a human only gets asked about what it structurally can't
observe.

- **Why AXUIElement, not XCUITest**: this is a Swift Package (`Package.swift`), not a
  hand-authored `.xcodeproj` (see "Build & run" in CLAUDE.md) — SPM has no UI-test-bundle target
  type that can host `XCUIApplication` against an external app. `Sources/QCHarness` is instead a
  plain executable target that drives the packaged `.app` from the outside via the Accessibility
  (AXUIElement) API — the same mechanism VoiceOver and other assistive tech use — requiring
  Accessibility permission granted to whatever process runs it (System Settings > Privacy &
  Security > Accessibility).
- **What it does**: `Scripts/qc.sh` kills any running instance, does a clean build into a real
  `.app` bundle (via `Scripts/package-app.sh`), launches it, waits for readiness, opens the menu
  bar popover, and drives ~20 scenarios — enumerating the track list, reading the title/labels,
  clicking transport controls, switching every playlist including BGM, and reading back state —
  each via the same accessibility identifiers/labels/values the SwiftUI views expose
  (`ContentView.swift`/`PlaylistBarApp.swift`). It writes a machine-readable `qc-report.json` and
  screenshots of the popover window only (never the full screen — see below).
- **Regression coverage**: dedicated scenarios re-test every previously-found-and-fixed bug listed
  in CLAUDE.md's per-feature QC history — BGM switch-away/switch-back history duplication
  (`bgm-006`), the hung-loading-spinner race (`volume-control-007`), duplicate error banners and
  the vanishing track list on a mid-session yt-dlp outage (`menu-bar-ui-005`, opt-in since it
  briefly renames the real `yt-dlp` binary — reversible, with a `defer`-based restore plus a
  bash-side safety net), the `ScrollView` collapse (`menu-bar-ui-003`), and the icon-only label's
  playing/paused glyph swap (`menu-bar-ui-004`). The one exception is the ~2x
  `AVFoundation`-duration-estimation bug (`playback-engine-005`): reproducing it live would mean
  playing a real track for several minutes, so that scenario is a **code-invariant check** instead
  — it asserts the trusted-duration watchdog (`AudioPlayer.swift`'s `knownEndWatchdog`) is still
  present, not a live behavioral replay. The 40-then-20-character menu bar *title text* truncation
  this backlog originally wanted covered no longer applies at all — it was removed outright by the
  icon-only label change (see CLAUDE.md's "Icon-only label" note) — so that scenario is recorded as
  `obsolete`/skipped rather than silently dropped.
- **What it still can't do**: confirm audio actually *sounds* right (no glitches, correct track),
  a physical media-key press (F7/F8/F9), whether a tooltip visually renders, or any judgment call
  that isn't reducible to an accessibility-tree assertion. Those stay in the `qc` skill's manual
  walkthrough.
- **Screenshot safety**: screenshots are captured by CoreGraphics window ID
  (`screencapture -l<windowNumber>`) scoped to the app's own popover window, never a full-screen
  grab — found live while building this that a naive full-screen capture can catch whatever
  unrelated content happens to be on screen at the time (an early prototype accidentally captured
  the developer's own email client).

## Explicitly out of scope

- No support for playlists beyond the 4 fixed ones and BGM; no UI to add/remove/edit the 4 fixed
  playlists (BGM's channel pool is likewise hardcoded in source for now — no in-app UI to add a
  channel, even though the underlying model is structured to support more than one).
- No shuffle mode, no repeat-single-track mode for the 4 fixed playlists (only whole-playlist
  looping via wrap-around) — this doesn't apply to BGM, whose whole point is randomized selection;
  see "BGM channel playback".
- No duration/seek bar.
- No account/sign-in of any kind.
- No sync across machines — this is single-Mac, local-only.
- No packaging/notarization/distribution — local build and run only.

## Security

Low risk, small surface:

- **No authentication, no accounts, no OAuth** — all 4 playlists and the BGM channel(s) are
  public; nothing in the app ever touches Frederic's YouTube account or credentials.
- **No secrets or API keys** — the yt-dlp approach was specifically chosen to avoid needing a
  YouTube Data API key or any Google Cloud credential.
- **No untrusted user input** — the only external data is public YouTube playlist metadata
  (video IDs/titles) and resolved stream URLs, both fetched read-only via yt-dlp. Titles are
  rendered as plain text in SwiftUI views (no HTML/JS execution), so there's no injection surface
  from playlist content.
- **Local data sensitivity**: cached playlist listings and last-played-track state are stored
  unencrypted under `~/Library/Application Support/PlaylistBar/`. This is not sensitive data
  (just video IDs/titles of playlists Frederic already plays), so no encryption/Keychain use is
  warranted. BGM's per-video local listen counts (added 2026-08-10) are the same kind of data —
  video ids and play counts, nothing that identifies Frederic beyond what the rest of the app's
  local state already does — stored the same unencrypted way; confirmed with Frederic as an
  acceptable risk level with no extra protection needed. The per-playlist saved seek position
  (added 2026-08-11) is the same category again — a plain number of elapsed seconds alongside a
  video id already being stored — no new sensitivity introduced.
- **BGM channel scanning** (added 2026-08-10): uses the same `yt-dlp --flat-playlist` mechanism,
  same trust boundary, and same public/read-only access as the 4 fixed playlists — no new
  authentication surface. Filtering out members-only ("subscriber_only") videos relies on that
  public availability marker yt-dlp already reports; the app never signs in or attempts to access
  members-only content itself.
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
