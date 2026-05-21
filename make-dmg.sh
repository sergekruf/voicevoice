#!/usr/bin/env bash
# Package VoiceVoice.app into a distributable .dmg image.
# Usage: ./make-dmg.sh
# Pre-req: ./build-app.sh release  (must have built build/VoiceVoice.app first)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VoiceVoice"
APP_DIR="$PROJECT_DIR/build/${APP_NAME}.app"
DMG_PATH="$PROJECT_DIR/build/${APP_NAME}.dmg"
VOLNAME="$APP_NAME"

if [[ ! -d "$APP_DIR" ]]; then
    echo "❌ $APP_DIR not found. Run ./build-app.sh release first."
    exit 1
fi

rm -f "$DMG_PATH"

# Stage the DMG contents in a temp dir so we can add an Applications symlink.
STAGE_DIR="/tmp/voicevoice-dmg-$$"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$STAGE_DIR"

echo "==> Staging .app and Applications symlink in $STAGE_DIR"
ditto "$APP_DIR" "$STAGE_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGE_DIR/Applications"

# Clean stray xattrs the OS likes to add; hdiutil tolerates these but it's cleaner.
xattr -cr "$STAGE_DIR" 2>/dev/null || true

echo "==> Building compressed DMG…"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null

# Compute SHA-256 so receiver can verify integrity.
SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')

echo
echo "✅ Готово: $DMG_PATH ($SIZE)"
echo "   SHA-256: $SHA"
echo
cat <<'EOF'
Что положить в сообщение получателю:

  1) Скопируй файл VoiceVoice.dmg.
  2) Открой его двойным кликом.
  3) Перетащи иконку VoiceVoice в папку Applications.
  4) Запусти VoiceVoice из Launchpad / Applications.
     При первом запуске macOS скажет «Cannot be opened because the developer
     cannot be verified» — щёлкни правой кнопкой по приложению → Open → Open.
     Это нужно один раз; потом запускается обычно.
  5) В появившемся окне онбординга разреши:
     • Микрофон
     • Accessibility (Privacy & Security → Accessibility)
     • Automation → System Events (всплывёт диалог при первом распознавании)
  6) Подожди 3–10 минут при первом запуске — Whisper-модель (~632 МБ) скачается
     и скомпилируется для Neural Engine. Дальше — мгновенно.
  7) Зажми Fn в любом приложении, говори, отпусти. Текст вставляется + копируется
     в буфер.
EOF
