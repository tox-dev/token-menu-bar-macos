#!/usr/bin/env bash
# Writes the version into App/project.yml before xcodegen reads it. With no argument it derives one from git, so a
# build off any commit is traceable; the release passes the tag explicitly.
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:-$(Scripts/version.sh --marketing)}"
source_version="${1:-$(Scripts/version.sh --full)}"
build="$(Scripts/version.sh --build)"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$version\"/" App/project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$build\"/" App/project.yml
sed -i '' "s/SOURCE_VERSION: \".*\"/SOURCE_VERSION: \"$source_version\"/" App/project.yml
echo "stamped $source_version ($build)"
