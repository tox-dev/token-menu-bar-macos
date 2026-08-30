#!/usr/bin/env bash
set -euo pipefail

directory="${1:?usage: notarize.sh <directory>}"
: "${APP_STORE_CONNECT_KEY_ID:?}"
: "${APP_STORE_CONNECT_ISSUER_ID:?}"
: "${APP_STORE_CONNECT_KEY_BASE64:?}"
key="$RUNNER_TEMP/AuthKey.p8"
echo "$APP_STORE_CONNECT_KEY_BASE64" | base64 --decode > "$key"

notarize() {
  xcrun notarytool submit "$1" --key "$key" --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" --wait
}

for app in "$directory"/*.app; do
  [[ -d "$app" ]] || continue
  archive="$RUNNER_TEMP/$(basename "$app" .app).zip"
  ditto -c -k --keepParent "$app" "$archive"
  notarize "$archive"
  xcrun stapler staple "$app"
  spctl --assess --type exec --verbose=2 "$app"
done

for dmg in "$directory"/*.dmg; do
  [[ -f "$dmg" ]] || continue
  notarize "$dmg"
  xcrun stapler staple "$dmg"
done
rm -f "$key"
