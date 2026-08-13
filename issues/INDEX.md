# Issues index

| ID | Title | Status | Security | Owner | Depends on |
|----|-------|--------|----------|-------|------------|
| app-shell-001 | Menu bar app scaffold | done | false | agent | |
| app-shell-002 | Quit menu item | done | false | agent | app-shell-001 |
| app-shell-003 | yt-dlp presence check | done | false | agent | app-shell-001 |
| playlist-data-001 | Cache schema & storage helpers | done | false | agent | |
| playlist-data-002 | yt-dlp flat-playlist scan | done | true | agent | playlist-data-001 |
| playlist-data-003 | Cache-first load with 24h staleness refresh | done | false | agent | playlist-data-002 |
| playback-engine-001 | Stream URL resolution via yt-dlp | done | true | agent | |
| playback-engine-002 | AVPlayer wrapper for a resolved stream URL | done | true | agent | playback-engine-001 |
| playback-engine-003 | Next-track preloading | done | false | agent | playback-engine-001, playback-engine-002 |
| playback-engine-004 | Unavailable-track auto-skip | done | false | agent | playback-engine-001, playback-engine-003 |
| playback-engine-005 | Feedback/resilience for throttled stream delivery | done | false | agent | playback-engine-001, playback-engine-002 |
| playback-engine-006 | Seek to a start position on load, with near-end clamp | done | false | agent | playback-engine-002, playback-engine-005 |
| playback-engine-007 | Bounded timeouts for stream resolution and playback buffering | done | false | agent | playback-engine-001, playback-engine-002, playback-engine-004 |
| player-state-001 | Per-playlist last-played-track persistence | done | false | agent | |
| player-state-002 | Last active playlist persistence | done | false | agent | player-state-001 |
| player-state-003 | Per-playlist last-played seek-position persistence | done | false | agent | player-state-001 |
| playback-controller-001 | Playlist switch orchestration | done | false | agent | playlist-data-003, playback-engine-002, player-state-001 |
| playback-controller-002 | Previous/Next with wrap-around | done | false | agent | playback-controller-001, player-state-001 |
| playback-controller-003 | Reset control | done | false | agent | playback-controller-002 |
| playback-controller-004 | Auto-advance on track completion | done | false | agent | playback-controller-002, playback-engine-004 |
| playback-controller-005 | Click-to-play from track list | done | false | agent | playback-controller-001 |
| playback-controller-006 | Persist and resume per-track seek position for the 4 fixed playlists | done | false | agent | player-state-003, playback-engine-006, playback-controller-001 |
| menu-bar-ui-001 | Playlist selector dropdown | done | false | agent | playback-controller-001 |
| menu-bar-ui-002 | Transport controls | done | false | agent | playback-controller-002, playback-controller-003 |
| menu-bar-ui-003 | Track list (previous 5 / current / next 5) | done | false | agent | playback-controller-005, playlist-data-003 |
| menu-bar-ui-004 | Menu bar icon + current track title | done | false | agent | playback-controller-001 |
| menu-bar-ui-005 | yt-dlp missing / unavailable messaging | done | false | agent | app-shell-003, playlist-data-002, playback-engine-001 |
| menu-bar-ui-006 | Loading/buffering visual feedback across all wait moments | done | false | agent | playback-controller-001, playback-engine-005 |
| startup-001 | Launch-at-Login toggle | done | false | agent | app-shell-001 |
| startup-002 | Idle launch with restored selection (no auto-play) | done | false | agent | player-state-002, playback-controller-001 |
| system-integration-001 | Now Playing info | done | false | agent | playback-engine-002, playback-controller-001 |
| system-integration-002 | Media key (F7/F8/F9) support | done | false | agent | playback-controller-002, system-integration-001 |
| volume-control-001 | AVPlayer volume control with persisted app-wide level | done | false | agent | |
| volume-control-002 | Volume slider in the dropdown | done | false | agent | volume-control-001 |
| volume-control-003 | Per-track loudness measurement via ffmpeg | done | true | agent | |
| volume-control-004 | Persist measured per-track gain in the playlist cache | done | false | agent | volume-control-003 |
| volume-control-005 | Apply per-track normalization gain alongside master trim | done | false | agent | volume-control-001, volume-control-004 |
| volume-control-006 | Fold loudness analysis into next-track preloading | done | false | agent | volume-control-003, volume-control-004 |
| volume-control-007 | Bounded wait for loudness analysis on out-of-order jumps | done | false | agent | volume-control-003, volume-control-004, volume-control-005 |
| volume-control-008 | Surface loudness-analysis wait in existing loading/buffering feedback | done | false | agent | volume-control-007 |
| bgm-001 | BGM track cache schema & storage | done | false | agent | |
| bgm-002 | Channel scan with 15-minute / non-members-only filtering | done | true | agent | bgm-001 |
| bgm-003 | Cache-first pooled load with listen-count-preserving 24h refresh | done | false | agent | bgm-002 |
| bgm-004 | Fewest-listens / random-tiebreak selection algorithm | done | false | agent | bgm-001 |
| bgm-005 | Listen-count increment on playback threshold | done | false | agent | bgm-001, playback-engine-002 |
| bgm-006 | BGM switch-to + Next selection orchestration | done | false | agent | bgm-003, bgm-004, bgm-005, playback-controller-001 |
| bgm-007 | Session-only Previous history navigation | done | false | agent | bgm-006 |
| bgm-008 | Reset restarts the current BGM video instead of jumping | done | false | agent | bgm-006 |
| bgm-009 | Restore last-played BGM video on relaunch without auto-play | done | false | agent | bgm-006, startup-002 |
| bgm-010 | "BGM" entry in the playlist selector dropdown | done | false | agent | bgm-006, menu-bar-ui-001 |
| bgm-011 | BGM track list — history + current, no "next" slot | done | false | agent | bgm-005, bgm-006, bgm-007 |
| bgm-012 | Persist and resume BGM's saved seek position | done | false | agent | player-state-003, playback-engine-006, bgm-006, bgm-009 |
| bgm-013 | Measure listen-count threshold relative to resume, not absolute position | done | false | agent | bgm-005, bgm-012 |
