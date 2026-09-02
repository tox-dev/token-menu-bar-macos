#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:?usage: package-direct.sh <semver>}"
out="${OUT_DIR:-dist/direct}"
archive_basename="${ARCHIVE_BASENAME:-TokenMenuBar}"
expected_distribution="${EXPECTED_DISTRIBUTION:-Direct}"
expected_updater="${EXPECTED_UPDATER:-required}"
app="$out/Token Menu Bar.app"
[[ -d "$app" ]] || {
  echo "missing $app"
  exit 1
}
Scripts/verify-app-bundle.sh "$app" "$expected_distribution" "$expected_updater"

rm -f "$out/$archive_basename.zip" "$out/$archive_basename.dmg"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/$archive_basename.zip"

staging="$(mktemp -d)"
extracted="$(mktemp -d)"
mount_point="$(mktemp -d)"
device=""
cleanup() {
  if [[ -n "$device" ]]; then hdiutil detach "$device" > /dev/null || true; fi
  rm -rf "$staging" "$extracted" "$mount_point"
}
trap cleanup EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
# ULMO mounts on macOS 10.15 and later, below the app's macOS 14 deployment floor.
hdiutil create -volname "Token Menu Bar $version" -srcfolder "$staging" -ov -format ULMO -fs HFS+ \
  "$out/$archive_basename.dmg" > /dev/null

if codesign -dv "$app" 2>&1 | grep -q "Developer ID Application"; then
  codesign --force --sign "Developer ID Application" --timestamp "$out/$archive_basename.dmg"
fi

ditto -x -k "$out/$archive_basename.zip" "$extracted"
Scripts/verify-app-bundle.sh "$extracted/Token Menu Bar.app" "$expected_distribution" "$expected_updater"
attach_output="$(hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$out/$archive_basename.dmg")"
device="$(awk '$1 ~ /^\/dev\// { value=$1 } END { print value }' <<< "$attach_output")"
[[ -n "$device" ]] || {
  echo "could not identify the mounted DMG device" >&2
  exit 1
}
Scripts/verify-app-bundle.sh "$mount_point/Token Menu Bar.app" "$expected_distribution" "$expected_updater"
hdiutil detach "$device" > /dev/null
device=""

for file in "$out/$archive_basename.zip" "$out/$archive_basename.dmg"; do
  shasum -a 256 "$file" | awk '{print $1}' > "$file.sha256"
done
cleanup
trap - EXIT
ls -la "$out"
