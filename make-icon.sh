#!/usr/bin/env bash
# Generate AppIcon.icns for VoiceVoice using SF Symbols → all macOS icon sizes.
# Re-run this script if you want to change the icon look.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_ICNS="$PROJECT_DIR/Sources/VoiceVoice/Resources/AppIcon.icns"
STAGE="/tmp/voicevoice-icon-$$"
ICONSET="$STAGE/AppIcon.iconset"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$ICONSET"

cat > "$STAGE/render.swift" <<'SWIFTEOF'
import AppKit
import Foundation

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: swift render.swift <size> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let size = CGFloat(Int(CommandLine.arguments[1]) ?? 1024)
let outPath = CommandLine.arguments[2]

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Rounded-square background with red gradient. iOS/macOS-style icon shape uses
// a 22% corner radius — same as Apple's own icon grid.
let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                          xRadius: size * 0.22, yRadius: size * 0.22)
if let gradient = NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.31, blue: 0.27, alpha: 1.0),
                             ending: NSColor(srgbRed: 0.74, green: 0.13, blue: 0.13, alpha: 1.0)) {
    gradient.draw(in: bgPath, angle: -90)
}

// White SF Symbol microphone, centered, ~58% of the icon.
if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.58, weight: .semibold)
    if let resolved = mic.withSymbolConfiguration(config) {
        let tinted = NSImage(size: resolved.size)
        tinted.lockFocus()
        NSColor.white.set()
        let rect = NSRect(origin: .zero, size: resolved.size)
        resolved.draw(in: rect)
        rect.fill(using: .sourceIn)
        tinted.unlockFocus()
        let drawSize = resolved.size
        tinted.draw(in: NSRect(x: (size - drawSize.width) / 2,
                               y: (size - drawSize.height) / 2,
                               width: drawSize.width, height: drawSize.height))
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
SWIFTEOF

echo "==> Rendering icon at all required sizes…"
# Required iconset entries: name → pixel size
declare -a entries=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)
for e in "${entries[@]}"; do
    name="${e%%:*}"
    px="${e##*:}"
    swift "$STAGE/render.swift" "$px" "$ICONSET/$name"
done

echo "==> Compiling .icns with iconutil…"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"

echo
echo "✅ Иконка собрана: $OUT_ICNS"
echo "   Запусти ./build-app.sh release  и затем ./make-dmg.sh,"
echo "   чтобы пересобрать .app и .dmg с новой иконкой."
