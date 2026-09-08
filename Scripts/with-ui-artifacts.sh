#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/check-test-desktop.sh

artifact_root="$HOME/Library/Containers/${UI_RUNNER_ID:-dev.tox.token-menu-bar.application-ui-tests.xctrunner}/Data/tmp"
mkdir -p "$artifact_root" .build/ui-artifacts
artifact_directory="$(mktemp -d "$artifact_root/token-menu-bar-ui.XXXXXX")"
trap 'ditto "$artifact_directory" .build/ui-artifacts; rm -rf "$artifact_directory"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TEST_RUNNER_TMB_BENCHMARK_OUTPUT_DIR="$artifact_directory" "$@"
