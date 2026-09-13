#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
SCHEME=TokenMenuBar-Homebrew CONFIGURATION=Homebrew OUT_DIR=dist/homebrew \
  EXPECTED_DISTRIBUTION=Homebrew EXPECTED_UPDATER=forbidden \
  Scripts/build-direct.sh
