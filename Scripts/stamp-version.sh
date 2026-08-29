#!/usr/bin/env bash
# Writes the release version into App/project.yml; the build number is the number of commits on the branch.
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:?usage: stamp-version.sh <semver>}"
build="$(git rev-list --count HEAD)"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$version\"/" App/project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$build\"/" App/project.yml
echo "stamped $version ($build)"
