#!/bin/bash

set -e

echo "📲 Installing existing build to device..."

IPA_PATH="./build/export/score.ipa"
EXPORT_PATH="./build/export"
APP_PATH="$EXPORT_PATH/Payload/score.app"

if [ ! -f "$IPA_PATH" ]; then
    echo "❌ No build found at $IPA_PATH"
    echo "Run ./deploy-to-device.sh first to create a build"
    exit 1
fi

# Get device ID
DEVICE_ID=$(xcrun xctrace list devices 2>&1 | grep -m1 "iPhone" | grep -v "Simulator" | sed -E 's/.*\(([A-F0-9-]+)\)$/\1/' || true)

if [ -z "$DEVICE_ID" ]; then
    echo "❌ Could not find connected iPhone"
    exit 1
fi

echo "Installing to device: $DEVICE_ID"

# Extract and install
echo "Extracting .app bundle from IPA..."
unzip -q -o "$IPA_PATH" -d "$EXPORT_PATH"

if [ -d "$APP_PATH" ]; then
    ios-deploy --bundle "$APP_PATH" --id "$DEVICE_ID"
    echo "✅ Successfully installed!"
else
    echo "❌ Could not find extracted app bundle at $APP_PATH"
    exit 1
fi

echo ""
echo "🎉 Done! The app has been installed on your iPhone and Apple Watch."
