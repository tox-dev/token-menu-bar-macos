#!/usr/bin/env bash
# Archives the Direct scheme and exports a Developer ID (or ad-hoc) signed app into dist/direct.
set -euo pipefail

cd "$(dirname "$0")/.."
signed="${SIGNED:-false}"
out="dist/direct"
archive="$out/TokenMenuBar.xcarchive"
rm -rf "$out"
mkdir -p "$out"

if [[ "$signed" == "true" ]]; then
  xcodebuild -project App/TokenMenuBar.xcodeproj -scheme TokenMenuBar-Direct -configuration Release \
    -destination 'platform=macOS' -archivePath "$archive" \
    DEVELOPMENT_TEAM="${TEAM_ID:?}" SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}" archive | tail -20
  cat > "$out/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/export.plist" -exportPath "$out" | tail -20
else
  xcodebuild -project App/TokenMenuBar.xcodeproj -scheme TokenMenuBar-Direct -configuration Release \
    -destination 'platform=macOS' -archivePath "$archive" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}" archive | tail -20
  cp -R "$archive/Products/Applications/Token Menu Bar.app" "$out/"
  codesign --force --deep --sign - "$out/Token Menu Bar.app"
fi

codesign --verify --deep --strict --verbose=2 "$out/Token Menu Bar.app"
echo "exported $out/Token Menu Bar.app (signed=$signed)"
