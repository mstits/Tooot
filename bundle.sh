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
    <string>2.0.0</string>
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

    <!-- Declare .mad as a native document type so Finder double-click opens ToooT,
         Quick Look can preview it, and Spotlight knows about the extension.
         mdimporter plugin for actual rich content indexing is a follow-up. -->
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key><string>ToooT Project</string>
        <key>CFBundleTypeRole</key><string>Editor</string>
        <key>LSHandlerRank</key><string>Owner</string>
        <key>LSItemContentTypes</key>
        <array><string>com.apple.projecttooot.mad</string></array>
      </dict>
    </array>

    <key>UTExportedTypeDeclarations</key>
    <array>
      <dict>
        <key>UTTypeIdentifier</key><string>com.apple.projecttooot.mad</string>
        <key>UTTypeDescription</key><string>ToooT Project (MAD)</string>
        <key>UTTypeConformsTo</key>
        <array><string>public.data</string><string>public.content</string></array>
        <key>UTTypeTagSpecification</key>
        <dict>
          <key>public.filename-extension</key><array><string>mad</string></array>
          <key>public.mime-type</key><array><string>application/x-tooot-mad</string></array>
        </dict>
      </dict>
    </array>
</dict>
</plist>
PLIST

echo "Codesigning app bundle..."
codesign --force --deep --sign - "$APP_NAME"

echo "App bundle created and signed at $APP_NAME"
