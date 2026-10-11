#!/usr/bin/env bash
# Build, install and launch the iOS app on a simulator and save a screenshot of it.
#
#   scripts/screenshot.sh [options] OUT.png
#     --sim NAME       simulator device name (default "iPhone 17 Pro"; created on the newest iOS runtime if missing)
#     --udid UDID      use this simulator instead of --sim
#     --args "..."     launch arguments, e.g. "-seedSampleMatches -seedActiveMatch -showNewMatchSheet" (see DebugSeed.swift)
#     --dark           capture in dark mode (light otherwise)
#     --no-build       reuse the last build in .build/sim
#     --wait SECS      seconds between launch and capture (default 3)
#
# The build is a Debug simulator build in .build/sim (separate from `make build`); the status bar is
# overridden to 9:41 / full battery. Output goes to OUT.png (directories are created).
set -euo pipefail
cd "$(dirname "$0")/.."

sim="iPhone 17 Pro"; udid=""; args=""; dark=0; build=1; wait=3; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim=$2; shift 2 ;;
    --udid) udid=$2; shift 2 ;;
    --args) args=$2; shift 2 ;;
    --dark) dark=1; shift ;;
    --no-build) build=0; shift ;;
    --wait) wait=$2; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) out=$1; shift ;;
  esac
done
[[ -n "$out" ]] || { echo "usage: scripts/screenshot.sh [options] OUT.png (see --help)" >&2; exit 2; }
[[ -n "$udid" ]] || udid=$(scripts/simulator-udid.sh "$sim")

app=.build/sim/Build/Products/Debug-iphonesimulator/score.app
bundle_id=armincerf.score
mkdir -p .build/logs "$(dirname "$out")"

if [[ $build -eq 1 ]]; then
  # /usr/bin first: Homebrew's rsync breaks xcodebuild's copy phases
  set -o pipefail
  PATH="/usr/bin:$PATH" xcodebuild build -project score.xcodeproj -scheme score \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath .build/sim \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee .build/logs/screenshot-build.log | scripts/xcb.sh
fi
[[ -d "$app" ]] || { echo "no build at $app (run without --no-build)" >&2; exit 1; }

xcrun simctl boot "$udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl ui "$udid" appearance $([[ $dark -eq 1 ]] && echo dark || echo light)
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null
xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app"
# shellcheck disable=SC2086  # $args is a space-separated list of launch arguments on purpose
xcrun simctl launch "$udid" "$bundle_id" $args >/dev/null
sleep "$wait"
xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1
echo "$out"
