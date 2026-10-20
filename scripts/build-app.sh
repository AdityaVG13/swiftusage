#!/bin/zsh
# Builds SwiftUsage.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/SwiftUsage.app"
VERSION=1.0.0

swift build -c release --product swiftusage
BIN="$(swift build -c release --show-bin-path)/swiftusage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/swiftusage"

ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# The bundle ID keeps the app's old name, so its settings and caches carry over to SwiftUsage.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>swiftusage</string>
    <key>CFBundleIdentifier</key><string>dev.tasteskill.UsageGraphs</string>
    <key>CFBundleName</key><string>SwiftUsage</string>
    <key>CFBundleDisplayName</key><string>SwiftUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # UsageGraphs and "Usage Graphs.app" are the names it had before it was SwiftUsage.
    pkill -x swiftusage 2>/dev/null && sleep 0.5 || true
    pkill -x UsageGraphs 2>/dev/null && sleep 0.5 || true
    rm -rf "/Applications/SwiftUsage.app" "/Applications/Usage Graphs.app"
    cp -R "$APP" /Applications/
    open "/Applications/SwiftUsage.app"
    echo "Installed to /Applications and launched"
fi
