#!/bin/sh
# build.sh: Skeleton (Mantra).app. Run by GitHub Actions only (never on the Mac). VERSION is in app/App.swift.
set -e
cd "$(dirname "$0")"
mkdir -p build
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
APP="build/Skeleton (Mantra).app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/Skeleton" app/*.swift
cp icon/AppIcon.icns data/poses.json "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Skeleton (Mantra)</string>
<key>CFBundleDisplayName</key><string>Skeleton (Mantra)</string>
<key>CFBundleIdentifier</key><string>community.auroville.skeleton</string>
<key>CFBundleExecutable</key><string>Skeleton</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>Skeleton (Mantra) looks at the camera you choose and draws your body pose on it. Nothing leaves this Mac.</string>
<key>NSCameraUseContinuityCameraDeviceType</key><true/>
</dict></plist>
PL
codesign --force -s "${SIGN:--}" "$APP"
echo "built $APP (v$V)"
