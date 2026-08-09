---
id: playback-engine-001
title: Stream URL resolution via yt-dlp
status: done
security: true
owner: agent
depends_on: []
spec_ref: "SPEC.md#playback-engine"
---

## Description

Implement a function that resolves a playable, audio-only direct stream URL for a given YouTube
video ID by shelling out to yt-dlp (e.g. requesting `bestaudio` format and the direct URL).
Distinguish a genuinely unavailable video (deleted/private/region-locked) from other errors so
callers can decide to skip it.

## Acceptance criteria

- Given a valid video id, returns a playable audio stream URL.
- Given an unavailable video id, returns a distinct "unavailable" result rather than throwing an
  unhandled error or crashing.
- The subprocess is invoked via `Process` with an argument array (video id passed as a discrete
  argument) — never interpolated into a shell string, to avoid command-injection risk from video
  ids/titles that originate from YouTube data.
- Stream URLs are resolved on demand (not pre-resolved in bulk for a whole playlist), since they
  expire after a few hours per SPEC.md.

## Notes

**Security rationale:** executes an external process with a dynamic argument (video id) and
treats yt-dlp's output as untrusted third-party data. Flagged per SPEC.md's Security section.

This issue only resolves the URL; actual playback is playback-engine-002.

Implemented as `StreamResolver.resolve(videoID:)` in `Sources/PlaylistBar/StreamResolver.swift`,
built on the same `YtDlpRunner` shared with playlist-data-002 (resolves yt-dlp's absolute path via
`YtDlpLocator` rather than bare-name PATH lookup, arguments always passed as an array). Runs
`yt-dlp -f bestaudio -g <watch-url>`, which prints just the direct stream URL to stdout on
success. The video id is embedded in a single watch-URL argv string (`.../watch?v=<id>`), never
passed through a shell, so there's no command-injection surface regardless of what the id
contains.

Distinguishing "unavailable" from other failures: yt-dlp exits non-zero for both cases with no
structured error code, so `unavailabilityMarkers` matches known phrasing
("Video unavailable", "Private video", region/age-gate messages, etc.) case-insensitively against
stderr. This is a best-effort, not exhaustive, heuristic — flagging in case real-world testing
(playback-engine-004's auto-skip) turns up an unavailability message not on this list, which would
currently surface as a thrown `ResolutionError.processFailed` instead of `.unavailable`.

Verified against real videos:
- An available track (`bbMxtNt8jHw`, the first Jazz playlist track) resolved to a genuine
  `https://*.googlevideo.com/videoplayback?...` URL (`itag=251`, Opus audio-only — confirms
  `bestaudio` correctly avoids pulling video).
- A nonexistent video id (`aaaaaaaaaaa`) correctly returned `.unavailable` (matched on yt-dlp's
  actual "Video unavailable" stderr message) rather than throwing.

Did not have a known private/region-locked/age-gated video id on hand to test those specific
marker strings live — only the "Video unavailable" path was exercised against a real yt-dlp
response; the others are pattern-matched defensively but unverified against real yt-dlp output.

**Correctness fix found while implementing playback-engine-002 (AVPlayer wrapper):** the original
`-f bestaudio` selector picked YouTube's highest-bitrate audio-only stream, which is typically
WebM/Opus (itag 251) — a container/codec combination AVFoundation does not natively decode on
macOS. `AVPlayerItem` never reached `.readyToPlay` for that URL (confirmed both by direct testing
and by the fact that a plain `curl` fetch of the same URL succeeded with `Content-Type:
audio/webm`, ruling out a network problem). Changed the format selector to
`"bestaudio[ext=m4a]/bestaudio"` — M4A/AAC (itag 140) is available for virtually every YouTube
video, is natively decodable by AVFoundation, and still falls back to plain `bestaudio` for the
rare video with no M4A track at all (that fallback case is unverified — no test video found
without an M4A option). Re-verified end-to-end after the fix: real playback advanced through real
time and the natural-end callback fired correctly (see playback-engine-002's notes) — much
stronger evidence than the original resolution-only test, which only confirmed the URL was
well-formed, not that it was actually playable.

**Security review:** `security: true`. `/security-review` still requires a git repository, which
this project doesn't have yet (same limitation noted on playlist-data-002) — did a manual pass:
argument array (no shell), video id can't be mistaken for a flag since it's embedded inside a
larger URL string, yt-dlp's stdout/stderr treated purely as data never executed. Worth a real
`/security-review` pass once this project has a git repo.
