#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
: "${TEAM_ID:?}"
: "${APP_STORE_CONNECT_KEY_ID:?}"
: "${APP_STORE_CONNECT_ISSUER_ID:?}"
: "${APP_STORE_CONNECT_KEY_BASE64:?}"
# The profile names have to match the ones installed on the runner and the ones the project archives with.
APP_PROFILE="${APP_PROFILE:-Token Menu Bar App Store}"
WIDGET_PROFILE="${WIDGET_PROFILE:-Token Menu Bar Widget App Store}"
out="dist/app-store"
archive="$out/TokenMenuBar.xcarchive"
key="$RUNNER_TEMP/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
echo "$APP_STORE_CONNECT_KEY_BASE64" | base64 --decode > "$key"
rm -rf "$out"
mkdir -p "$out"

xcodebuild -project App/TokenMenuBar.xcodeproj -scheme TokenMenuBar-AppStore -configuration AppStore \
  -destination 'platform=macOS' -archivePath "$archive" DEVELOPMENT_TEAM="$TEAM_ID" archive | tail -20

app="$archive/Products/Applications/Token Menu Bar.app"
Scripts/verify-deployment-targets.sh "$app" 14.0
Scripts/verify-app-bundle.sh "$app" "App Store" forbidden

cat > "$out/export.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>installerSigningCertificate</key><string>Mac Installer Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>dev.tox.token-menu-bar</key><string>${APP_PROFILE}</string>
    <key>dev.tox.token-menu-bar.widget</key><string>${WIDGET_PROFILE}</string>
  </dict>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/export.plist" -exportPath "$out" \
  -allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID" | tail -30
rm -f "$key"
