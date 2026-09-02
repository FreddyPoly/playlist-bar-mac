# Migrating to another Mac

Notes for moving PlaylistBar from this Mac (M4) to another Mac (M5). Both are Apple Silicon
(arm64), so there's no cross-architecture concern — a plain `swift build` on the new machine
produces a native build with no special flags.

## What transfers

The project is a plain Swift Package — no machine-specific config baked into the source. Copy (or
`git clone`) the project folder itself:

- If a git remote exists (`git remote -v`), just clone it on the new Mac.
- Otherwise, copy the folder directly (external drive, AirDrop, `rsync`, etc.). Skip `dist/`,
  `.build/`, `qc-report.json`, and `qc-screenshots/` — all regenerable, not needed.

## What does NOT transfer automatically

Per-machine runtime state lives outside the repo, at
`~/Library/Application Support/PlaylistBar/` on each Mac independently:

- `*.json` playlist/BGM caches — fine to lose; rebuilt automatically on first run via a fresh
  yt-dlp scan.
- `player-state.json` — last-played track/playlist, master volume, and saved per-track seek
  positions. Starts fresh on the new Mac unless copied over manually.

**To preserve playback state**, copy the whole
`~/Library/Application Support/PlaylistBar/` directory from the old Mac to the same path on the
new Mac before first launch.

## Dependencies to install on the new Mac

- Xcode / Swift toolchain (to run `swift build`)
- `brew install yt-dlp`
- `brew install ffmpeg` (for per-track loudness normalization — see CLAUDE.md's "Build & run")

Both installed via Homebrew at `/opt/homebrew/bin` on Apple Silicon — the codebase's
`YtDlpAvailability.swift`/`FfmpegAvailability.swift` already search that path explicitly (not just
inherited `PATH`), so no PATH setup is needed beyond a normal `brew install`.

## Steps on the new Mac

```bash
brew install yt-dlp ffmpeg
```

From the project folder:

```bash
swift build
swift run
```

For the real packaged `.app` (needed for Launch-at-Login / `SMAppService`):

```bash
./Scripts/package-app.sh
open dist/PlaylistBar.app
```

See CLAUDE.md's "Build & run" section for more detail on each of these.
