---
id: bgm-002
title: Channel scan with 15-minute / non-members-only filtering
status: open
security: true
owner: agent
depends_on: [bgm-001]
spec_ref: "SPEC.md#bgm-channel-playback"
---

## Description

Scan a YouTube channel's `/videos` tab via `yt-dlp --flat-playlist` and filter its entries down
to the ones eligible for the BGM pool: `duration >= 900` seconds (15 minutes) and
`availability != "subscriber_only"` (excludes members-only videos).

## Acceptance criteria

- Given a channel URL, scans its `/videos` tab (append `/videos` if not already present) via
  `yt-dlp --flat-playlist -J`, the same mechanism `playlist-data-002` uses for playlists.
- Confirmed live against the real configured channel
  (`https://www.youtube.com/channel/UC_LtBDXXXqQiIBNO2NwEOPQ`, "Deep Emotion BGM"): the scan
  returns `duration` and `availability` per entry directly — no extra per-video `yt-dlp` calls are
  needed to filter. Implementation should rely on these fields being present in the flat-playlist
  JSON rather than resolving each video individually.
- Returns only entries with `duration >= 900` and `availability` not equal to `"subscriber_only"`.
  A missing/`null` `availability` means not members-only (this is the common case — most videos
  have no `availability` value at all).
- The subprocess is invoked via an argument array (never shell-interpolated), same convention as
  `YtDlpRunner`/`PlaylistScanner`.
- Handles yt-dlp non-zero exit codes and malformed/unexpected JSON output without crashing the
  app (surfaces an error instead, same pattern as `playlist-data-002`).

## Notes

**Security rationale** (same reasoning as `playlist-data-002`): this executes an external process
and parses its JSON output, which is effectively third-party (YouTube) data, even though the
channel URL(s) themselves are fixed/hardcoded rather than user-entered.

Real numbers from the actual configured channel, gathered during the interview for this feature:
177 total videos on the `/videos` tab, 106 qualify under the filter above. Useful as a sanity
check when verifying this issue's implementation.

Reuse `YtDlpRunner` (from `playlist-data-002`) for subprocess execution rather than reimplementing
the deadlock-avoidance (concurrent stdout/stderr draining) it already handles.

Produces raw scanned+filtered results only — merging them into the persisted pool (preserving
existing listen counts) is `bgm-003`, not this issue.
