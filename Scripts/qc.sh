#!/bin/bash
# Automated QC harness: kills any running instance, does a clean build into a real .app bundle,
# launches it, waits for it to be ready, drives it end-to-end via Scripts/../Sources/QCHarness
# (an AXUIElement-based CLI — see Package.swift's comment on why this isn't XCUITest), and writes
# a machine-readable pass/fail report.
#
# This exists to eliminate manual guided QC as the *first* pass: run this before asking a human to
# click through anything (see the `qc` skill, which now runs this first). It cannot replace human
# judgment entirely — see the report's own notes on what it structurally can't observe (audible
# playback correctness, whether a color/tooltip actually renders, physical media-key presses) —
# but it removes the stale-instance and "did I actually see what I think I saw" failure modes that
# motivated building it (see SPEC.md's "Automated QC harness").
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PlaylistBar"
BUNDLE_ID="com.studiobleumoutarde.PlaylistBar"
APP_BUNDLE="$PROJECT_ROOT/dist/$APP_NAME.app"
REPORT_PATH="$PROJECT_ROOT/qc-report.json"
SCREENSHOT_DIR="$PROJECT_ROOT/qc-screenshots"
CONFIGURATION="release"
SKIP_YTDLP_OUTAGE=""
WAIT_TIMEOUT=20

while [ $# -gt 0 ]; do
    case "$1" in
        --debug) CONFIGURATION="debug" ;;
        --skip-ytdlp-outage) SKIP_YTDLP_OUTAGE="--skip-ytdlp-outage" ;;
        --report) REPORT_PATH="$2"; shift ;;
        --screenshot-dir) SCREENSHOT_DIR="$2"; shift ;;
        --wait-timeout) WAIT_TIMEOUT="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

echo "== 1/6: Checking Accessibility permission =="
# osascript's own "UI elements enabled" check reflects whether *this* process tree has been
# granted Accessibility — the same grant QCHarness itself checks via AXIsProcessTrusted() right
# before it does anything else. Fail fast here with the fix instead of letting the harness fail
# deep into a scenario.
if [ "$(osascript -e 'tell application "System Events" to return UI elements enabled' 2>/dev/null || echo false)" != "true" ]; then
    echo "error: Accessibility permission not granted to this terminal/process." >&2
    echo "Grant it via System Settings > Privacy & Security > Accessibility, then re-run." >&2
    exit 1
fi

echo "== 2/6: Killing any running $APP_NAME instance =="
pkill -x "$APP_NAME" 2>/dev/null || true
# Give the old process (and its status item) a moment to actually disappear — starting the next
# step while a stale instance is still tearing down is exactly the "stale app instance" false
# positive this harness exists to eliminate.
for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.25
done
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "error: $APP_NAME is still running after pkill — refusing to test against a stale instance." >&2
    exit 1
fi

echo "== 3/6: Clean build ($CONFIGURATION) =="
rm -rf "$PROJECT_ROOT/.build/$CONFIGURATION"
"$PROJECT_ROOT/Scripts/package-app.sh" "$CONFIGURATION"
swift build -c "$CONFIGURATION" --package-path "$PROJECT_ROOT" --product QCHarness
QCHARNESS_BIN="$(swift build -c "$CONFIGURATION" --package-path "$PROJECT_ROOT" --show-bin-path)/QCHarness"
if [ ! -x "$QCHARNESS_BIN" ]; then
    echo "error: QCHarness binary not found at $QCHARNESS_BIN" >&2
    exit 1
fi

echo "== 4/6: Launching $APP_BUNDLE =="
open "$APP_BUNDLE"

echo "== 5/6: Running scenario suite =="
rm -rf "$SCREENSHOT_DIR"
mkdir -p "$SCREENSHOT_DIR"
set +e
"$QCHARNESS_BIN" \
    --bundle-id "$BUNDLE_ID" \
    --report "$REPORT_PATH" \
    --screenshot-dir "$SCREENSHOT_DIR" \
    --source-root "$PROJECT_ROOT" \
    --wait-timeout "$WAIT_TIMEOUT" \
    $SKIP_YTDLP_OUTAGE
HARNESS_EXIT=$?
set -e

echo "== 6/6: Safety-net check for yt-dlp restoration =="
# Belt-and-suspenders on top of QCHarness's own `defer`-based restore (scenario
# "17-ytdlp-outage-error-handling"): if that process was killed abnormally mid-scenario instead of
# throwing/returning normally, its `defer` would never have run. Catch that here rather than
# leaving a real Homebrew-managed binary renamed on this machine.
for candidate in /opt/homebrew/bin/yt-dlp /usr/local/bin/yt-dlp; do
    if [ -e "$candidate.qc-hidden" ]; then
        echo "warning: restoring $candidate left hidden by an interrupted QC run" >&2
        mv "$candidate.qc-hidden" "$candidate"
    fi
done

echo
if [ -f "$REPORT_PATH" ]; then
    python3 -c "
import json
with open('$REPORT_PATH') as f:
    report = json.load(f)
s = report['summary']
print(f\"Summary: {s['passed']}/{s['total']} passed, {s['failed']} failed, {s['skipped']} skipped\")
for sc in report['scenarios']:
    if sc['status'] != 'passed':
        marker = 'FAIL' if sc['status'] == 'failed' else 'SKIP'
        print(f\"  [{marker}] {sc['name']}: {sc['message']}\")
"
else
    echo "error: no report was written to $REPORT_PATH" >&2
fi

exit $HARNESS_EXIT
