#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AppVolume"
APP="${APP_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building ${APP_NAME}..."

# Clean previous build
rm -rf "$APP"

# Create app bundle structure
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy app icon
if [[ -f "AppIcon.icns" ]]; then
    cp "AppIcon.icns" "$RESOURCES/AppIcon.icns"
else
    echo "Warning: AppIcon.icns not found. Building without custom icon."
fi

# Locate macOS SDK
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Compile Swift source
xcrun swiftc \
    -O \
    -sdk "$SDK" \
    -target arm64-apple-macos15.0 \
    -framework AppKit \
    -framework CoreAudio \
    AppVolume.swift \
    -o "$MACOS/$APP_NAME"

# Generate Info.plist
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
<dict>

    <key>CFBundleExecutable</key>
    <string>AppVolume</string>

    <key>CFBundleIdentifier</key>
    <string>local.austin.AppVolume</string>

    <key>CFBundleName</key>
    <string>AppVolume</string>

    <key>CFBundleDisplayName</key>
    <string>AppVolume</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>

    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>

    <key>CFBundleVersion</key>
    <string>1</string>

    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>

    <key>NSHighResolutionCapable</key>
    <true/>

    <key>NSAudioCaptureUsageDescription</key>
    <string>AppVolume needs system audio access to control the volume of individual apps.</string>

</dict>
</plist>
PLIST

# Validate plist
plutil -lint "$CONTENTS/Info.plist"

# Ad-hoc sign for local development
codesign \
    --force \
    --deep \
    --sign - \
    "$APP"

echo
echo "Build complete."
echo
echo "App created at:"
echo "  $(pwd)/$APP"
echo
echo "Run with:"
echo "  open \"$APP\""