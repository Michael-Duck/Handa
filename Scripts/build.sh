#!/bin/bash
# Builds Handa.app from the Swift package.
#
#   Scripts/build.sh              release build for this Mac
#   Scripts/build.sh --universal  release build for Apple silicon and Intel
#   Scripts/build.sh --debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Handa.app"

if [ "$UNIVERSAL" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Handa"
else
  swift build -c "$CONFIG"
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/Handa"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Handa"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
[ "$CONFIG" = release ] && strip -x "$APP/Contents/MacOS/Handa"

# Ad-hoc signature so macOS will run it. Signed builds for distribution need a Developer ID.
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP ($VERSION, $(du -sh "$APP" | cut -f1))"
