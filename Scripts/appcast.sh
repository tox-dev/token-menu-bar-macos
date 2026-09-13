#!/usr/bin/env bash
# Generates dist/direct/appcast.xml for Sparkle from the release zip. Local builds may pass --unsigned; releases fail
# before publishing an appcast that Sparkle cannot verify.
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:?usage: appcast.sh <semver>}"
mode="${2:-}"
[[ -z "$mode" || "$mode" == "--unsigned" ]] || {
  echo "usage: appcast.sh <semver> [--unsigned]" >&2
  exit 1
}
out="dist/direct"
download_prefix="https://github.com/tox-dev/token-menu-bar-macos/releases/download/v${version}/"

generate_appcast="$(
  find ~/Library/Developer/Xcode/DerivedData "$PWD/App" -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' \
    -type f 2> /dev/null |
    head -1 || true
)"
if [[ "$mode" != "--unsigned" ]]; then
  [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]] || {
    echo "SPARKLE_PRIVATE_ED_KEY is required; pass --unsigned for a local appcast" >&2
    exit 1
  }
  [[ -x "$generate_appcast" ]] || {
    echo "Sparkle generate_appcast was not found in DerivedData or App" >&2
    exit 1
  }
  echo "$SPARKLE_PRIVATE_ED_KEY" |
    "$generate_appcast" --ed-key-file - --download-url-prefix "$download_prefix" "$out"
  grep -q 'sparkle:edSignature=' "$out/appcast.xml" || {
    echo "generated appcast has no Sparkle EdDSA signature" >&2
    exit 1
  }
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
echo "wrote unsigned local appcast"
