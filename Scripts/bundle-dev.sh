#!/usr/bin/env bash
# Builds the SwiftPM executable and wraps it in a minimal, ad-hoc signed .app for local development on machines
# without Xcode. Pass --run for real provider data or --run-demo for an isolated verification launch.
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-debug}"
out="${OUT_DIR:-dist}"
app="$out/Token Menu Bar.app"
version="$(Scripts/version.sh --marketing)"
source_version="$(Scripts/version.sh --full)"
build="$(Scripts/version.sh --build)"

swift build -c "$configuration" --product TokenMenuBar
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
binary="$bin_dir/TokenMenuBar"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/TokenMenuBar"
resource_bundle="$bin_dir/TokenMenuBar_TokenMenuBarUI.bundle"
if [[ ! -d "$resource_bundle" ]]; then
  echo "missing SwiftPM resource bundle: $resource_bundle" >&2
  exit 1
fi
cp -R "$resource_bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>TokenMenuBar</string>
  <key>CFBundleIdentifier</key><string>dev.tox.token-menu-bar</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>Token Menu Bar</string>
  <key>CFBundleDisplayName</key><string>Token Menu Bar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build}</string>
  <key>TMBSourceVersion</key><string>${source_version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
iconset="$(mktemp -d)/TokenMenuBar.iconset"
"$binary" --export-icon "$iconset" > /dev/null
iconutil --convert icns --output "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf "$iconset"

codesign --force --sign - "$app"
echo "built $app"

case "${1:-}" in
  --run)
    pkill -x TokenMenuBar || true
    open "$app"
    ;;
  --run-demo)
    pkill -x TokenMenuBar || true
    open "$app" --args --verify-ui
    ;;
  "") ;;
  *)
    echo "usage: $0 [--run|--run-demo]" >&2
    exit 2
    ;;
esac
