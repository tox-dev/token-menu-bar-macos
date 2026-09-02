#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
signed="${SIGNED:-false}"
scheme="${SCHEME:-TokenMenuBar-Direct}"
configuration="${CONFIGURATION:-Release}"
out="${OUT_DIR:-dist/direct}"
expected_distribution="${EXPECTED_DISTRIBUTION:-Direct}"
expected_updater="${EXPECTED_UPDATER:-required}"
archive="$out/TokenMenuBar.xcarchive"
verification_key="${SPARKLE_PUBLIC_ED_KEY:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=}"
rm -rf "$out"
mkdir -p "$out"

if [[ "$signed" == "true" ]]; then
  xcodebuild -project App/TokenMenuBar.xcodeproj -scheme "$scheme" -configuration "$configuration" \
    -destination 'platform=macOS' -archivePath "$archive" \
    DEVELOPMENT_TEAM="${TEAM_ID:?}" SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:?}" \
    APP_GROUP_ID="${TEAM_ID}.dev.tox.token-menu-bar" SELF_UPDATE_ENABLED=YES archive | tail -20
  cat > "$out/export.plist" << PLIST
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
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/export.plist" \
    -exportPath "$out" | tail -20
else
  # The app group entitlement needs a provisioning profile, which an unsigned build has none of, so signing is off
  # for the archive and the bundle is ad-hoc signed below instead.
  xcodebuild -project App/TokenMenuBar.xcodeproj -scheme "$scheme" -configuration "$configuration" \
    -destination 'platform=macOS' -archivePath "$archive" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" SPARKLE_PUBLIC_ED_KEY="$verification_key" archive | tail -20
  cp -R "$archive/Products/Applications/Token Menu Bar.app" "$out/"
  codesign --force --deep --sign - "$out/Token Menu Bar.app"
fi

Scripts/verify-deployment-targets.sh "$out/Token Menu Bar.app" 14.0
Scripts/verify-app-bundle.sh "$out/Token Menu Bar.app" "$expected_distribution" "$expected_updater"
codesign --verify --deep --strict --verbose=2 "$out/Token Menu Bar.app"
echo "exported $out/Token Menu Bar.app (scheme=$scheme, signed=$signed)"
