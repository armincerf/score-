#!/usr/bin/env bash
# Run the app's VideoOrientationDetector on the Mac (Vision's body pose model has no compute device on the iOS
# simulator, so this is how to see its scores for real footage without a device build).
#
#   scripts/detect-orientation.sh <video>...                 scores + decision per video
#   scripts/detect-orientation.sh --selftest <png> <dir>     turn a picture of a person each way and check the decision
#
# The detector sources are compiled unchanged from score/ together with scripts/orientation/DetectOrientation.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

out=.build/orientation-cli
mkdir -p "$out"
binary="$out/detect-orientation"
sources=(score/Log.swift score/VideoRotationCorrection.swift score/VideoOrientationDetector.swift
  scripts/orientation/DetectOrientation.swift)

stale=0
[[ -x "$binary" ]] || stale=1
for source in "${sources[@]}"; do
  [[ "$source" -nt "$binary" ]] && stale=1
done
if [[ $stale == 1 ]]; then
  xcrun swiftc -O -swift-version 6 -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -o "$binary" "${sources[@]}" >"$out/build.log" 2>&1 || { cat "$out/build.log"; exit 1; }
fi
exec "$binary" "$@"
