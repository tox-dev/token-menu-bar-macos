#!/usr/bin/env bash
# Builds the SwiftPM executable and wraps it in a minimal, ad-hoc signed .app for local development on machines
# without Xcode. Pass --run to launch it afterwards.
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-debug}"
out="${OUT_DIR:-dist}"
app="$out/Token Menu Bar.app"
version="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' App/project.yml | head -1)"
build="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' App/project.yml | head -1)"

swift build -c "$configuration" --product TokenMenuBar
binary="$(swift build -c "$configuration" --show-bin-path)/TokenMenuBar"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/TokenMenuBar"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>TokenMenuBar</string>
  <key>CFBundleIdentifier</key><string>dev.tox.token-menu-bar</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Token Menu Bar</string>
  <key>CFBundleDisplayName</key><string>Token Menu Bar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "built $app"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x TokenMenuBar || true
  open "$app"
fi
