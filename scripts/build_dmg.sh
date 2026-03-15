#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release

BIN_PATH=""
for candidate in \
  ".build/release/notsy" \
  ".build/arm64-apple-macosx/release/notsy" \
  ".build/x86_64-apple-macosx/release/notsy"
do
  if [[ -x "$candidate" ]]; then
    BIN_PATH="$candidate"
    break
  fi
done

if [[ -z "$BIN_PATH" ]]; then
  BIN_PATH="$(find .build -type f -path "*/release/notsy" | head -n 1 || true)"
fi

if [[ -z "$BIN_PATH" || ! -x "$BIN_PATH" ]]; then
  echo "Could not find release binary for notsy." >&2
  exit 1
fi

cp "$BIN_PATH" "dist/Notsy.app/Contents/MacOS/notsy"

rm -rf "dist/dmgroot"
mkdir -p "dist/dmgroot"
cp -R "dist/Notsy.app" "dist/dmgroot/Notsy.app"
ln -s /Applications "dist/dmgroot/Applications"

hdiutil create -volname "Notsy" -srcfolder "dist/dmgroot" -ov -format UDZO "Notsy.dmg"
echo "Created Notsy.dmg with Applications shortcut."
