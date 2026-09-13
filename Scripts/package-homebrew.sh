#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR=dist/homebrew ARCHIVE_BASENAME=TokenMenuBar-Homebrew EXPECTED_DISTRIBUTION=Homebrew \
  EXPECTED_UPDATER=forbidden Scripts/package-direct.sh "${1:?usage: package-homebrew.sh <semver>}"
