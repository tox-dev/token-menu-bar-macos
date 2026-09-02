#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:?usage: update-cask.sh <semver> <dmg>}"
dmg="${2:?usage: update-cask.sh <semver> <dmg>}"
sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
sed -i '' "s/^  version \".*\"/  version \"$version\"/" Casks/token-menu-bar.rb
sed -i '' "s/^  sha256 \".*\"/  sha256 \"$sha\"/" Casks/token-menu-bar.rb
cat Casks/token-menu-bar.rb
