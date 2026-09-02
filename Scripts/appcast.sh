#!/usr/bin/env bash
# Generates dist/direct/appcast.xml for Sparkle from the release zip. Without SPARKLE_PRIVATE_ED_KEY the appcast is
# written unsigned so the release still ships; Sparkle refuses unsigned feeds, so set the key before shipping updates.
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:?usage: appcast.sh <semver>}"
out="dist/direct"
download_prefix="https://github.com/tox-dev/token-menu-bar-macos/releases/download/v${version}/"

sparkle_bin="$(
  find ~/Library/Developer/Xcode/DerivedData "$PWD/App" -path '*artifacts/sparkle/Sparkle/bin' -type d 2> /dev/null |
    head -1 || true
)"
if [[ -n "$sparkle_bin" && -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
  echo "$SPARKLE_PRIVATE_ED_KEY" |
    "$sparkle_bin/generate_appcast" --ed-key-file - --download-url-prefix "$download_prefix" "$out"
  exit 0
fi

length="$(stat -f %z "$out/TokenMenuBar.zip")"
build="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' App/project.yml | head -1)"
cat > "$out/appcast.xml" << XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Token Menu Bar</title>
    <item>
      <title>${version}</title>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${download_prefix}TokenMenuBar.zip" length="${length}" type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML
echo "wrote unsigned appcast (set SPARKLE_PRIVATE_ED_KEY to sign)"
