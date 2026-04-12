#!/bin/bash
set -e

APP_NAME="ToooT.app"
EXECUTABLE=".build/arm64-apple-macosx/debug/ProjectToooTApp"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Executable not found. Building..."
    swift build
fi

echo "Creating bundle structure..."
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

echo "Copying executable..."
cp "$EXECUTABLE" "$APP_NAME/Contents/MacOS/ToooT"

echo "Creating Info.plist..."
cat << PLIST > "$APP_NAME/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ToooT</string>
    <key>CFBundleIdentifier</key>
    <string>com.apple.projecttooot</string>
    <key>CFBundleName</key>
    <string>ToooT</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>ToooT requires microphone access to record audio.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>ToooT requires screen capture access to record its output.</string>
    <key>NSCameraUsageDescription</key>
    <string>ToooT requires camera access for certain features.</string>
</dict>
</plist>
PLIST

echo "Codesigning app bundle..."
codesign --force --deep --sign - "$APP_NAME"

echo "App bundle created and signed at $APP_NAME"
