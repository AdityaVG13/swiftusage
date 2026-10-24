#!/bin/zsh
# Makes a release of SwiftUsage, at the version in VERSION, in ./dist: the app for Apple silicon and
# Intel, signed with a Developer ID, notarized and stapled, as a disk image and a zip, with their SHA-256
# sums, release notes from CHANGELOG.md, the app's debug symbols, and feed.json, which tells copies
# already installed about the release so they update themselves. It also uploads the debug symbols to
# PostHog, where the app's crash reports go, so they name the functions a crash happened in.
#
# Notarizing uses the credentials notarytool keeps in the keychain as $NOTARY_PROFILE ("swiftusage" by
# default), and the upload the login posthog-cli keeps; the README's Releasing section shows how to save
# both. --skip-notarization makes the same files unnotarized, for checking the packaging, but Gatekeeper
# turns those away on other Macs, and uploads no symbols.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=$(<VERSION)
APP="$ROOT/build/SwiftUsage.app"
DIST="$ROOT/dist"
NAME="SwiftUsage-$VERSION"
PROFILE=${NOTARY_PROFILE:-swiftusage}
# PostHog's EU cloud, where Telemetry.swift sends the statistics and crash reports.
POSTHOG_HOST=https://eu.posthog.com

notarize=true
for argument in "$@"; do
    case $argument in
        --skip-notarization) notarize=false ;;
        *) echo "Unknown option $argument (use --skip-notarization)" >&2; exit 64 ;;
    esac
done

# Everything that can stop the release is checked before the build.
if ! command -v uvx >/dev/null; then
    echo "The disk image is laid out with dmgbuild, which runs through uv: brew install uv" >&2
    exit 1
fi
if $notarize && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "notarytool has no working credentials saved as \"$PROFILE\" (see the README's Releasing section)." >&2
    echo "Set NOTARY_PROFILE to use others, or pass --skip-notarization." >&2
    exit 1
fi
if $notarize && ! command -v posthog-cli >/dev/null; then
    echo "The debug symbols are uploaded to PostHog with posthog-cli: brew install posthog/tap/posthog-cli," >&2
    echo "then posthog-cli --host $POSTHOG_HOST login." >&2
    exit 1
fi
if ! grep -qxF "## $VERSION" CHANGELOG.md; then
    echo "CHANGELOG.md has no section for $VERSION." >&2
    exit 1
fi
if [[ -n $(git status --porcelain) ]]; then
    if $notarize; then
        echo "The working tree has uncommitted changes. Commit them first, so the release matches its commit." >&2
        exit 1
    fi
    echo "Warning: the working tree has uncommitted changes, and the release includes them." >&2
fi

WORK=$(mktemp -d /tmp/swiftusage-release.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Sends a file to Apple's notary service and waits for the verdict. If it's turned away, prints Apple's
# log of what was wrong and stops.
submit() {
    echo "Notarizing $(basename "$1")…"
    local result id verdict
    result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json) || true
    id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null) || true
    verdict=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null) || true
    if [[ $verdict != Accepted ]]; then
        echo "Apple's notary service answered ${verdict:-nothing usable} for $(basename "$1"):" >&2
        echo "$result" >&2
        [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
        exit 1
    fi
    echo "Accepted ($id)"
}

swift test
./scripts/build-app.sh --release

codesign --verify --strict --deep "$APP"
for arch in arm64 x86_64; do lipo "$APP/Contents/MacOS/swiftusage" -verify_arch $arch; done
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')

mkdir -p "$WORK/dist"

if $notarize; then
    ditto -c -k --keepParent "$APP" "$WORK/SwiftUsage.zip"
    submit "$WORK/SwiftUsage.zip"
    # The ticket goes in the app as well, so it opens on a Mac that's offline the first time.
    xcrun stapler staple -q "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/dist/$NAME.zip"

# The app beside a link to Applications, to drag it to.
uvx --quiet --from dmgbuild==1.6.7 dmgbuild -s scripts/dmg-settings.py -D app="$APP" SwiftUsage "$WORK/dist/$NAME.dmg"
codesign --force --timestamp --sign "$IDENTITY" "$WORK/dist/$NAME.dmg"
if $notarize; then
    submit "$WORK/dist/$NAME.dmg"
    xcrun stapler staple -q "$WORK/dist/$NAME.dmg"
    # What Gatekeeper decides for someone who downloads them.
    spctl --assess --type execute "$APP"
    spctl --assess --type open --context context:primary-signature "$WORK/dist/$NAME.dmg"
fi

ditto -c -k --keepParent "$APP.dSYM" "$WORK/dist/$NAME-dSYM.zip"
awk -v heading="## $VERSION" '$0 == heading { found = 1; next } found && /^## / { exit } found' CHANGELOG.md \
    | sed '/./,$!d' > "$WORK/dist/$NAME-notes.md"
git rev-parse HEAD > "$WORK/dist/COMMIT"
(cd "$WORK/dist" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)

# What the app's updater reads (Updater.swift) from the latest release: the version, the zip it downloads
# from this release, and its hash and size. Built as a property list, which plutil edits, then written
# out as JSON.
PLIST="$APP/Contents/Info.plist"
RELEASES=$(plutil -extract SwiftUsageReleases raw "$PLIST")
FEED="$WORK/feed.plist"
plutil -create xml1 "$FEED"
plutil -insert version -string "$VERSION" "$FEED"
plutil -insert build -integer "$(plutil -extract CFBundleVersion raw "$PLIST")" "$FEED"
plutil -insert minimumSystemVersion -string "$(plutil -extract LSMinimumSystemVersion raw "$PLIST")" "$FEED"
plutil -insert url -string "$RELEASES/download/v$VERSION/$NAME.zip" "$FEED"
plutil -insert sha256 -string "$(shasum -a 256 "$WORK/dist/$NAME.zip" | cut -d' ' -f1)" "$FEED"
plutil -insert size -integer "$(stat -f%z "$WORK/dist/$NAME.zip")" "$FEED"
plutil -convert json -r -o "$WORK/dist/feed.json" "$FEED"

rm -rf "$DIST"
mv "$WORK/dist" "$DIST"

# Only for a release that can go out. A failed upload leaves the release as it is and says how to try again.
if $notarize; then
    upload=(posthog-cli --host "$POSTHOG_HOST" dsym upload --directory "$(dirname "$APP")" --main-dsym "$(basename "$APP").dSYM"
        --release-name "$(plutil -extract CFBundleIdentifier raw "$PLIST")" --release-version "$VERSION"
        --build "$(plutil -extract CFBundleVersion raw "$PLIST")")
    if ! "${upload[@]}"; then
        echo "Warning: the debug symbols didn't reach PostHog, so its crash reports from this build won't name functions." >&2
        echo "Sign in with posthog-cli --host $POSTHOG_HOST login if needed, then run: ${(j: :)${(q)upload[@]}}" >&2
    fi
fi

echo "\nSwiftUsage $VERSION, signed by $IDENTITY$($notarize && echo ', notarized and stapled' || echo ', NOT notarized'):"
ls -lh "$DIST" | sed 1d
