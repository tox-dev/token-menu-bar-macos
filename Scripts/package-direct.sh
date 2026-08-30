#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:?usage: package-direct.sh <semver>}"
out="dist/direct"
app="$out/Token Menu Bar.app"
[[ -d "$app" ]] || { echo "missing $app"; exit 1; }

rm -f "$out/TokenMenuBar.zip" "$out/TokenMenuBar.dmg"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/TokenMenuBar.zip"

staging="$(mktemp -d)"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Token Menu Bar $version" -srcfolder "$staging" -ov -format UDZO -fs HFS+ \
  "$out/TokenMenuBar.dmg" >/dev/null
rm -rf "$staging"

if codesign -dv "$app" 2>&1 | grep -q "Developer ID Application"; then
  codesign --force --sign "Developer ID Application" --timestamp "$out/TokenMenuBar.dmg"
fi

for file in "$out/TokenMenuBar.zip" "$out/TokenMenuBar.dmg"; do
  shasum -a 256 "$file" | awk '{print $1}' > "$file.sha256"
done
ls -la "$out"
