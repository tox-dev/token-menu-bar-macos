#!/usr/bin/env bash
# Refreshes the docs screenshots from the installed app running on demo data: the menu bar cells, every popover tab in light and dark
# mode, and a GIF cycling through the tabs. Requires the app in /Applications and screen-recording permission for
# the terminal running it. Restores the system appearance when done.
set -euo pipefail

cd "$(dirname "$0")/.."
app="${APP_PATH:-/Applications/Token Menu Bar.app}"
out="${OUT_DIR:-docs/images}"
bundle="dev.tox.token-menu-bar"
mkdir -p "$out"

frames() {
  swift Scripts/window-frames.swift "Token Menu Bar"
}

largest_window_id() {
  frames | python3 -c 'import json,sys; w=json.load(sys.stdin); print(max(w,key=lambda x:x["width"]*x["height"])["id"] if w else "")'
}

# The status item sits centred above the popover; capture a strip of the menu bar around that point.
menu_bar_region() {
  frames | python3 -c 'import json,sys; w=max(json.load(sys.stdin),key=lambda x:x["width"]*x["height"]); mid=w["x"]+w["width"]/2; print(f"{int(mid-200)},0,400,25")'
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
  open --env TOKEN_MENU_BAR_DEMO=1 "$app"
  sleep 6
  open "$app"
  sleep 3
  local id
  id="$(largest_window_id)"
  if [[ -z "$id" ]]; then
    echo "popover window not found for $tab" >&2
    return 1
  fi
  screencapture -x -o -l "$id" "$out/popover-$(tr '[:upper:]' '[:lower:]' <<<"$tab")-$suffix.png"
}

original_dark="$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')"
trap 'set_dark_mode "$original_dark"; quit_app; open "$app"' EXIT

for mode in light dark; do
  [[ "$mode" == dark ]] && set_dark_mode true || set_dark_mode false
  for tab in Usage History Settings; do
    capture_tab "$tab" "$mode"
  done
  screencapture -x -R "$(menu_bar_region)" "$out/menubar-$mode.png"
done

magick -delay 250 -loop 0 "$out/popover-usage-dark.png" "$out/popover-history-dark.png" "$out/popover-settings-dark.png" \
  -resize 1200x "$out/popover-tour.gif"
echo "screenshots written to $out"
ls -la "$out"
