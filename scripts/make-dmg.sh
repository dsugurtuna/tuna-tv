#!/usr/bin/env bash
# Packages "Tuna TV.app" into a compressed, drag-to-install DMG.
# Usage: scripts/make-dmg.sh "<path/to/Tuna TV.app>" <output.dmg>
set -euo pipefail
APP="$1"
OUT="$2"
[ -d "$APP" ] || { echo "App bundle not found: $APP" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
STAGE="$(mktemp -d /tmp/tunatv-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Tuna TV is free and open source, but it is not notarized by Apple.

1. Drag "Tuna TV" onto "Applications".
2. The first time, macOS may say it cannot verify the app. Either:
   - open System Settings > Privacy & Security and click "Open Anyway", or
   - run this once in Terminal:
       xattr -dr com.apple.quarantine "/Applications/Tuna TV.app"

Source code, releases and help: https://github.com/dsugurtuna/tuna-tv
TXT
rm -f "$OUT"
hdiutil create -volname "Tuna TV" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT"
echo "DMG: $OUT ($(du -h "$OUT" | cut -f1))"
