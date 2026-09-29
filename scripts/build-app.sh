#!/bin/sh
set -eu

PROJECT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${MACHINEPULSE_CONFIGURATION:-release}
OUTPUT_DIRECTORY=${MACHINEPULSE_OUTPUT_DIRECTORY:-"$PROJECT_DIRECTORY/dist"}

cd "$PROJECT_DIRECTORY"
swift build -c "$CONFIGURATION" --product MachinePulseApp >&2
BIN_DIRECTORY=$(swift build -c "$CONFIGURATION" --show-bin-path)

STAGING_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/machinepulse-build.XXXXXX")
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT

STAGED_APP="$STAGING_DIRECTORY/MachinePulse.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIRECTORY/MachinePulseApp" "$STAGED_APP/Contents/MacOS/MachinePulse"
cp "$PROJECT_DIRECTORY/Sources/MachinePulseApp/Resources/collector.sh" \
    "$STAGED_APP/Contents/Resources/collector.sh"
cp "$PROJECT_DIRECTORY/Config/MachinePulse-Info.plist" "$STAGED_APP/Contents/Info.plist"

plutil -replace CFBundleExecutable -string MachinePulse "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.davidweiszfeld.MachinePulse "$STAGED_APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 15.0 "$STAGED_APP/Contents/Info.plist"
plutil -extract CFBundleVersion raw -expect string "$STAGED_APP/Contents/Info.plist" >/dev/null
plutil -extract CFBundleShortVersionString raw -expect string "$STAGED_APP/Contents/Info.plist" >/dev/null

if [ -n "${MACHINEPULSE_CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$MACHINEPULSE_CODESIGN_IDENTITY" "$STAGED_APP"
else
    codesign --force --deep --sign - "$STAGED_APP"
fi
mkdir -p "$OUTPUT_DIRECTORY"
rm -rf "$OUTPUT_DIRECTORY/MachinePulse.app"
ditto "$STAGED_APP" "$OUTPUT_DIRECTORY/MachinePulse.app"

echo "$OUTPUT_DIRECTORY/MachinePulse.app"
