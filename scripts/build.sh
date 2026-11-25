#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ts3-fixer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/stage/TS3 Mac Fixer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"
# bibliothèque injectée dans le jeu (x86_64 : le jeu tourne sous Rosetta)
xcrun clang -arch x86_64 -mmacosx-version-min=10.13 -dynamiclib -fobjc-arc -O2 \
    -Wno-unguarded-availability-new -Wno-deprecated-declarations \
    -o "$ROOT/assets/libts3fix.dylib" "$ROOT"/dylib/*.m "$ROOT/dylib/fishhook.c" \
    -framework Foundation -framework AppKit -framework CoreGraphics -framework QuartzCore \
    -framework Metal -framework AudioToolbox -framework CoreAudio
codesign --force --sign - "$ROOT/assets/libts3fix.dylib"
for ARCH in arm64 x86_64; do
    xcrun swiftc -parse-as-library -O -target "$ARCH-apple-macos12.0" "$ROOT/app/main.swift" -o "$WORK/TS3MacFixes-$ARCH"
done
lipo -create "$WORK/TS3MacFixes-arm64" "$WORK/TS3MacFixes-x86_64" -output "$APP/Contents/MacOS/TS3MacFixes"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT"/assets/* "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
cp "$ROOT/app/Lisez-moi - Read me.txt" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname 'TS3 Mac Fixer' -srcfolder "$WORK/stage" -ov -format UDZO "$ROOT/dist/TS3 Mac Fixer.dmg"
hdiutil verify "$ROOT/dist/TS3 Mac Fixer.dmg"
