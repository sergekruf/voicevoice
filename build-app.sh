#!/usr/bin/env bash
# Build VoiceVoice.app bundle from the SwiftPM executable.
# Usage: ./build-app.sh [debug|release]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VoiceVoice"
BUNDLE_ID="com.sergekruf.voicevoice"
FINAL_APP_DIR="$PROJECT_DIR/build/${APP_NAME}.app"
INFO_PLIST="$PROJECT_DIR/Sources/VoiceVoice/Resources/Info.plist"
ENTITLEMENTS="$PROJECT_DIR/Sources/VoiceVoice/Resources/VoiceVoice.entitlements"

# Stage the bundle in /tmp (outside iCloud Drive) so codesign isn't sabotaged
# by iCloud's constant xattr injection on files under ~/Documents.
STAGE_DIR="/tmp/voicevoice-build-$$"
APP_DIR="$STAGE_DIR/${APP_NAME}.app"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "==> Building Swift package ($CONFIG)…"
swift build -c "$CONFIG" --arch arm64

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Binary not found at $BIN_PATH"; exit 1
fi

echo "==> Staging .app bundle at $APP_DIR (xattr-free)"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"

ICON_SRC="$PROJECT_DIR/Sources/VoiceVoice/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

BIN_DIR="$(dirname "$BIN_PATH")"
for r in "$BIN_DIR"/*.bundle; do
    [[ -d "$r" ]] && cp -R "$r" "$APP_DIR/Contents/Resources/"
done

printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Belt-and-suspenders: clear any xattrs the copy may have carried.
xattr -cr "$APP_DIR" 2>/dev/null || true

SIGN_IDENT="VoiceVoiceDev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENT\""; then
    echo "==> Codesigning with stable identity \"$SIGN_IDENT\"…"
    codesign --force --deep --sign "$SIGN_IDENT" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp=none \
        "$APP_DIR"
else
    echo "==> Stable identity \"$SIGN_IDENT\" not found, falling back to ad-hoc (TCC will not persist across rebuilds)."
    echo "    Run ./setup-signing.sh once to create a stable signing identity."
    codesign --force --deep --sign - \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        "$APP_DIR"
fi

echo "==> Verifying signature…"
if codesign --verify --deep --strict "$APP_DIR"; then
    echo "    Signature OK."
else
    echo "    ⚠︎ Signature verification failed — auto-paste will likely not work."
    exit 1
fi

echo "==> Installing to $FINAL_APP_DIR"
mkdir -p "$(dirname "$FINAL_APP_DIR")"
rm -rf "$FINAL_APP_DIR"
# Use ditto to preserve xattrs and Apple file metadata; this avoids producing a
# bundle that re-fails verification after the move.
ditto "$APP_DIR" "$FINAL_APP_DIR"

# Re-check the installed bundle. If iCloud's xattr injection happened during the
# copy, our signature is still preserved (cdhash unchanged).
echo "==> Final designated requirement:"
codesign -d -r- "$FINAL_APP_DIR" 2>&1 | grep designated || true

echo
echo "Готово: $FINAL_APP_DIR"
echo "Запуск:    open \"$FINAL_APP_DIR\""
echo "Логи:      log stream --predicate 'process == \"$APP_NAME\"' --info"
