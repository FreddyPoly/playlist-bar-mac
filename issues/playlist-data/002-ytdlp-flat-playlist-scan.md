---
id: playlist-data-002
title: yt-dlp flat-playlist scan
status: done
security: true
owner: agent
depends_on: [playlist-data-001]
spec_ref: "SPEC.md#playlist-data--caching"
---

## Description

Implement a function that shells out to `yt-dlp --flat-playlist` for one of the 4 hardcoded
playlist URLs (Rock3, Drum'N'Bass, Tranquille, Jazz — see SPEC.md) and parses the output into an
ordered list of `(video id, title)`, in the playlist's actual configured order (no reordering, no
shuffling).

## Acceptance criteria

- Given one of the 4 playlist URLs, returns its ordered track list (video id + title per track).
- The subprocess is invoked via `Process` with an argument array (e.g.
  `["--flat-playlist", "-J", url]`) — never by interpolating the URL into a shell string, to avoid
  any command-injection surface.
- Handles yt-dlp non-zero exit codes and malformed/unexpected JSON output without crashing the
  app (surfaces an error instead).
- Works correctly for large playlists (Rock3 ~2300 tracks, Drum'N'Bass ~1700 tracks) — no
  arbitrary truncation of results.

## Notes

**Security rationale:** this executes an external process with a dynamic-ish argument (the
playlist URL, though from a fixed hardcoded list) and parses yt-dlp's JSON output, which is
effectively a third-party API response. Flagged per SPEC.md's Security section note on
untrusted/third-party data handling, even though the 4 source URLs themselves are fixed and
trusted.

The 4 playlist URLs are hardcoded in the app (see SPEC.md) — this issue does not need to accept
arbitrary/user-entered playlist URLs.

Implemented as `PlaylistScanner.scan(playlistURL:)` in `Sources/PlaylistBar/PlaylistScanner.swift`,
backed by a new shared `YtDlpRunner` (`Sources/PlaylistBar/YtDlpRunner.swift`) used by both this
issue and (soon) playback-engine-001, since both need the same safe subprocess-invocation logic.
`YtDlpRunner` resolves yt-dlp's absolute path via `YtDlpLocator` (from app-shell-003) rather than
invoking it by bare name through PATH — same PATH-availability fix as the code-review finding on
`YtDlpAvailability.swift` applies here too, so scanning works regardless of how the app was
launched. Arguments are passed as an array (`["--flat-playlist", "-J", playlistURL]`), never
shell-interpolated.

**Deadlock fix applied proactively:** naive `Process`/`Pipe` usage (`waitUntilExit()` before
reading stdout, or reading stdout before stderr) deadlocks once output exceeds the ~64KB pipe
buffer — a near-certainty here, since large playlists' JSON output is hundreds of KB to low MBs.
`YtDlpRunner` drains stdout and stderr concurrently on background queues before waiting for exit.

Verified against all of this app's real fixed playlists' scale:
- Jazz (actual playlist, 178 tracks): full scan succeeded in ~1.8s, order and content correct.
- Rock3 (actual playlist, 2,448 tracks — slightly more than SPEC.md's ~2300 estimate): full scan
  succeeded in ~19s with no deadlock, no truncation, and all 2,448 video ids unique.
- An invalid playlist URL correctly throws `ScanError.processFailed` with yt-dlp's stderr
  captured, rather than crashing or hanging.

Did not additionally scan Drum'N'Bass or Tranquille given Jazz and Rock3 already cover the small
and large ends of this backlog's scale; happy to run those too if you want extra confidence.

**Security review:** this issue is `security: true`. `/security-review` couldn't run
automatically — it requires a git repository, and this project doesn't have one yet. Did a manual
security-focused pass instead: arguments are always passed as an array (never shell-interpolated,
so no command-injection surface even though `playlistURL` technically flows in from a constant);
yt-dlp's JSON output (third-party data) is parsed via `Codable` with optional fields and
`compactMap`, never executed or interpreted as anything but data; malformed/unexpected output
raises `ScanError.invalidOutput` rather than crashing or silently corrupting the cache. Worth
running `/security-review` for real once this project has a git repo.
