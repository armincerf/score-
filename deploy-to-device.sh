#!/bin/bash

set -e

echo "🏗️  Building production release for iOS and Watch..."

# Configuration
PROJECT="score.xcodeproj"
SCHEME="score"
BUILD_DIR="./build"
ARCHIVE_PATH="$BUILD_DIR/score.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
IPA_PATH="$EXPORT_PATH/score.ipa"

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Archive the app
echo "📦 Archiving app in Release configuration..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_STYLE=Automatic \
  | xcbeautify 2>/dev/null || cat

# Create export options plist
echo "📝 Creating export options..."
cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
EOF

# Export the archive
echo "📤 Exporting IPA..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
  | xcbeautify 2>/dev/null || cat

# Find connected devices
echo "📱 Looking for connected devices..."
DEVICE_LIST=$(xcrun devicectl list devices 2>/dev/null | grep "iPhone" || xcrun xctrace list devices 2>/dev/null | grep "iPhone" || true)

if [ -z "$DEVICE_LIST" ]; then
    echo "❌ No iPhone found. Please connect your device."
    echo ""
    echo "💡 To see available devices, run:"
    echo "   xcrun devicectl list devices"
    exit 1
fi

echo "Found devices:"
echo "$DEVICE_LIST"
echo ""

# Get device ID (prefer xctrace for physical devices as it gives proper UDID)
DEVICE_ID=$(xcrun xctrace list devices 2>&1 | grep -m1 "iPhone" | grep -v "Simulator" | sed -E 's/.*\(([A-F0-9-]+)\)$/\1/' || true)

if [ -z "$DEVICE_ID" ]; then
    echo "❌ Could not determine device ID"
    exit 1
fi

echo "Installing to device: $DEVICE_ID"

# Install on device (this will also install the Watch app on paired Watch)
echo "📲 Installing on iPhone (and paired Apple Watch)..."

# Extract .app from IPA for ios-deploy
APP_PATH="$EXPORT_PATH/Payload/score.app"
if command -v ios-deploy &> /dev/null; then
    echo "Extracting .app bundle from IPA..."
    unzip -q -o "$IPA_PATH" -d "$EXPORT_PATH"

    if [ -d "$APP_PATH" ]; then
        ios-deploy --bundle "$APP_PATH" --id "$DEVICE_ID"
        echo "✅ Successfully installed using ios-deploy!"
    else
        echo "❌ Could not find extracted app bundle at $APP_PATH"
        exit 1
    fi
else
    echo "⚠️  ios-deploy not found. Please install it:"
    echo "   brew install ios-deploy"
    exit 1
fi

echo ""
echo "🎉 Done! The production build has been installed on your iPhone and Apple Watch."
echo "📦 IPA location: $IPA_PATH"
