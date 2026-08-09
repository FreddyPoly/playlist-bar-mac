---
id: volume-control-003
title: Per-track loudness measurement via ffmpeg
status: done
security: true
owner: agent
depends_on: []
spec_ref: "SPEC.md#volume--loudness-normalization"
---

## Description

Add a function that measures a single track's integrated loudness and returns a normalization
gain, using `ffmpeg`'s `loudnorm` filter in analysis-only mode against the track's already-
resolved stream URL (from `StreamResolver`).

## Acceptance criteria

- Given a resolved stream URL, runs `ffmpeg` with the `loudnorm` filter in single-pass,
  analysis-only mode (reads/decodes the audio once, writes no output file) and parses the
  reported measured integrated loudness (LUFS).
- Computes a gain: `min(1.0, linear(-14 LUFS) / linear(measured LUFS))` — i.e. cut-only toward a
  -14 LUFS integrated target; a track already quieter than -14 LUFS gets gain `1.0` (never
  boosted above its original loudness).
- `ffmpeg` is located the same way `yt-dlp` is (see `YtDlpLocator`) — resolves an absolute path
  via PATH plus the Homebrew install directories (`/opt/homebrew/bin`, `/usr/local/bin`), not a
  bare-name PATH lookup, since a login-item-launched app doesn't inherit an interactive shell's
  PATH.
- Invoked with an explicit argument array (no shell string-interpolation) — same convention as
  `YtDlpRunner` — even though the current input (a stream URL this app itself resolved) isn't
  attacker-controlled.
- Returns a clear failure (not a crash, not a hang) when `ffmpeg` is missing, the stream is
  unreachable, or output can't be parsed — callers decide what to do with a failure (see
  `volume-control-007`).

## Notes

Added 2026-08-09. New runtime dependency: `ffmpeg`, installed by the user via
`brew install ffmpeg` (documented in `CLAUDE.md`'s Build & run section alongside `yt-dlp`).

**Open question, not decided during the interview**: whether a persistently-missing `ffmpeg`
should surface any UI indicator (like `menu-bar-ui-005`'s yt-dlp-missing banner) or degrade
silently (every track just plays unnormalized forever, same as any other analysis failure). SPEC.md
doesn't require a specific UX here — this issue only needs to return failure cleanly; the calling
issues (`006`, `007`) need to not hang or crash on repeated failure, but adding a dedicated
"ffmpeg unavailable" UI affordance is left as a possible future issue, not required by this one.

Flagged `security: true` since it's a new subprocess execution surface (new external binary,
argument handling) — not because the current input is untrusted, per SPEC.md's Security section
guidance on `ffmpeg invocation`.

**Implemented 2026-08-09**: `FfmpegAvailability.swift` (`FfmpegLocator`, a straight mirror of
`YtDlpLocator`) and `LoudnessAnalyzer.swift` (`measureGain(url:)`), running
`ffmpeg -hide_banner -nostats -i <url> -af loudnorm=print_format=json -f null -` via `Process`
with an argument array, draining stdout/stderr concurrently (same deadlock-avoidance pattern as
`YtDlpRunner`), parsing `loudnorm`'s trailing JSON block out of stderr for `input_i`, and
converting to a cut-only gain (`min(1.0, 10^((-14 - measured)/20))`, `1.0` for anything at/below
target or non-finite).

**Verification**: `ffmpeg` isn't installed on this machine yet — per this project's own
convention (documented in SPEC.md/CLAUDE.md), it's installed by the user via
`brew install ffmpeg`, not automated by the agent, same as `yt-dlp`. So this couldn't be verified
end-to-end against a real stream. What *was* verified: the JSON-parsing and gain-formula logic
against a realistic `loudnorm` stderr sample (log lines + trailing JSON block, matching ffmpeg's
actual output shape), via a standalone script — quiet track → gain 1.0 (never boosted), loud
track → correctly attenuated, exactly-at-target → 1.0, non-finite/silence input → falls back to
1.0 instead of NaN, malformed input → parses as `nil` rather than crashing. **Once `ffmpeg` is
installed, this needs one real live check** (a genuinely loud real track measuring plausibly, and
the actual subprocess invocation succeeding against a real resolved stream URL) before this can
be considered fully verified — flagging this rather than silently claiming full verification.
Reviewed manually in place of `/code-review` and `/security-review` (no git repo yet; this issue
is `security: true`) — no issues found in the manual pass.
