#!/bin/zsh
# Builds SwiftUsage.app into ./build, signed ad hoc for this Mac. Pass --install to copy it to
# /Applications and launch it.
#
# --release builds it for Apple silicon and Intel and signs it with the keychain's Developer ID
# Application certificate (or $SIGN_IDENTITY) and the hardened runtime, as scripts/release.sh
# notarizes it. Its debug symbols are kept beside it, in build/SwiftUsage.app.dSYM.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/SwiftUsage.app"
VERSION=$(<VERSION)
# Counts commits, so each release's build number is higher than the last one's.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
# Where the releases are published. The app checks the latest one's feed.json for updates, and
# scripts/release.sh points the feed at the zip it publishes there.
RELEASES=https://github.com/Blueemi/swiftusage/releases

release=false
install=false
for argument in "$@"; do
    case $argument in
        --release) release=true ;;
        --install) install=true ;;
        *) echo "Unknown option $argument (use --release, --install)" >&2; exit 64 ;;
    esac
done

if $release; then
    IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}
    if [[ -z $IDENTITY ]]; then
        echo "No Developer ID Application certificate in the keychain. Set SIGN_IDENTITY to the one to use." >&2
        exit 1
    fi
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi

swift build -c release --product swiftusage $ARCHS
PRODUCTS="$(swift build -c release --show-bin-path $ARCHS)"

rm -rf "$APP" "$APP.dSYM"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/swiftusage" "$APP/Contents/MacOS/swiftusage"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"

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
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>swiftusage</string>
    <key>CFBundleIdentifier</key><string>dev.tasteskill.UsageGraphs</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>SwiftUsage</string>
    <key>CFBundleDisplayName</key><string>SwiftUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <!-- The Intel half is for Intel Macs; on Apple silicon it never opens under Rosetta, which macOS 28 drops. -->
    <key>LSRequiresNativeExecution</key><true/>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 @blueemi99</string>
    <key>SwiftUsageReleases</key><string>$RELEASES</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

if $release; then
    # The symbols go in the dSYM, which symbolicates crash reports, and out of the app.
    cp -R "$PRODUCTS/swiftusage.dSYM" "$APP.dSYM"
    strip -x "$APP/Contents/MacOS/swiftusage"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Built $APP $VERSION ($BUILD), signed by $IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null
    echo "Built $APP $VERSION ($BUILD)"
fi

if $install; then
    # UsageGraphs and "Usage Graphs.app" are the names it had before it was SwiftUsage.
    pkill -x swiftusage 2>/dev/null && sleep 0.5 || true
    pkill -x UsageGraphs 2>/dev/null && sleep 0.5 || true
    rm -rf "/Applications/SwiftUsage.app" "/Applications/Usage Graphs.app"
    cp -R "$APP" /Applications/
    open "/Applications/SwiftUsage.app"
    echo "Installed to /Applications and launched"
fi
