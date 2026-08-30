#!/usr/bin/env bash
# Refreshes the website screenshots. The app renders them itself on demo data, so a shot never depends on how
# crowded this machine's menu bar is, what sits behind the popover, or which display the popover opened on.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${OUT_DIR:-website/assets/images}"
binary="${APP_BINARY:-dist/Token Menu Bar.app/Contents/MacOS/TokenMenuBar}"

if [[ ! -x "$binary" ]]; then
  echo "building the app bundle first" >&2
  CONFIGURATION=release Scripts/bundle-dev.sh >/dev/null
fi

mkdir -p "$out"
"$binary" --export-menubar "$out"
"$binary" --export-popover "$out"

magick -delay 250 -loop 0 "$out/popover-usage-dark.png" "$out/popover-history-dark.png" \
  "$out/popover-settings-dark.png" -resize 1200x "$out/popover-tour.gif"

echo "screenshots written to $out"
ls -la "$out"
