#!/usr/bin/env bash
# Refreshes the docs screenshots from the installed app running on demo data: the menu bar cells, every popover tab in light and dark
# mode, and a GIF cycling through the tabs. Requires the app in /Applications and screen-recording permission for
# the terminal running it. Restores the system appearance when done.
set -euo pipefail

cd "$(dirname "$0")/.."
app="${APP_PATH:-/Applications/Token Menu Bar.app}"
out="${OUT_DIR:-website/assets/images}"
bundle="dev.tox.token-menu-bar"
mkdir -p "$out"

frames() {
  swift Scripts/window-frames.swift "Token Menu Bar"
}

# screencapture -l cannot grab windows on some secondary displays, so capture the popover's frame as a region instead.
largest_window_region() {
  frames | python3 -c 'import json,sys; w=json.load(sys.stdin); w=max(w,key=lambda x:x["width"]*x["height"]) if w else None; print("%d,%d,%d,%d" % (w["x"],w["y"],w["width"],w["height"]) if w else "")'
}


quit_app() {
  pkill -x TokenMenuBar 2>/dev/null || true
  sleep 1
}

set_dark_mode() {
  osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" >/dev/null
  sleep 1
}

capture_tab() {
  local tab="$1" suffix="$2"
  quit_app
  defaults write "$bundle" lastTab "$tab"
  defaults write "$bundle" historyRange Today
  defaults write "$bundle" historyRollup Minute
  open --env TOKEN_MENU_BAR_DEMO=1 "$app"
  sleep 6
  open "$app"
  sleep 3
  local region
  region="$(largest_window_region)"
  if [[ -z "$region" ]]; then
    echo "popover window not found for $tab" >&2
    return 1
  fi
  screencapture -x -R "$region" "$out/popover-$(tr '[:upper:]' '[:lower:]' <<<"$tab")-$suffix.png"
}

original_dark="$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')"
trap 'set_dark_mode "$original_dark"; quit_app; open "$app"' EXIT

for mode in light dark; do
  [[ "$mode" == dark ]] && set_dark_mode true || set_dark_mode false
  for tab in Usage History Settings; do
    capture_tab "$tab" "$mode"
  done
done

# The menu bar strip is rendered by the app itself, so it never depends on how crowded this machine's bar is.
"$(dirname "$0")/../dist/Token Menu Bar.app/Contents/MacOS/TokenMenuBar" --export-menubar "$out" >/dev/null

magick -delay 250 -loop 0 "$out/popover-usage-dark.png" "$out/popover-history-dark.png" "$out/popover-settings-dark.png" \
  -resize 1200x "$out/popover-tour.gif"
echo "screenshots written to $out"
ls -la "$out"
