#!/usr/bin/env bash
# Build a Release build for a connected iPhone and install it (with the embedded watch
# app) using Xcode's devicectl. No ios-deploy, no archive/export step.
#
#   scripts/deploy-device.sh             # build + install + launch
#   scripts/deploy-device.sh --no-build  # install the last build
#   DEVICE="Alex's iPhone" scripts/deploy-device.sh   # pick a device by name/UDID
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-Release}
DERIVED=.build/device
APP="$DERIVED/Build/Products/$CONFIG-iphoneos/score.app"
BUNDLE_ID=armincerf.score
mkdir -p .build/logs

if [[ "${1:-}" != "--no-build" ]]; then
  echo "🏗️  Building $CONFIG for iOS device..."
  xcodebuild build -project score.xcodeproj -scheme score -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
    2>&1 | tee .build/logs/deploy.log | scripts/xcb.sh
fi

[[ -d "$APP" ]] || { echo "❌ No app bundle at $APP (run without --no-build first)"; exit 1; }

if [[ -z "${DEVICE:-}" ]]; then
  json=$(mktemp)
  trap 'rm -f "$json"' EXIT
  xcrun devicectl list devices --json-output "$json" >/dev/null
  DEVICE=$(python3 -I - "$json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
phones = [d for d in devices if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"]
connected = [d for d in phones if d.get("connectionProperties", {}).get("tunnelState") == "connected"]
if connected:
    print(connected[0]["identifier"])
else:
    names = ", ".join(f'{d["deviceProperties"]["name"]} ({d["connectionProperties"].get("tunnelState")})' for d in phones) or "none"
    sys.stderr.write(f"❌ No connected iPhone. Known iPhones: {names}\nConnect the phone (USB or same Wi-Fi) and unlock it, or set DEVICE=<name|udid>.\n")
    sys.exit(1)
PY
)
fi

echo "📲 Installing $APP on $DEVICE..."
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "🚀 Launching $BUNDLE_ID..."
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || true
echo "🎉 Done. The embedded watch app is installed on the paired Apple Watch by iOS."
