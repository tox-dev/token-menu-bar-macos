#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-benchmark-runtime.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
gh api repos/actions/runner-images/releases/tags/xcode-27-arm64%2F20260907.0173 |
  GITHUB_OUTPUT="$scratch/matrix" GITHUB_STEP_SUMMARY="$scratch/summary" UI_GROUP=performance \
    bash Scripts/ci-runtime-matrix.sh
latest="$(sed -n 's/^runtimes=//p' "$scratch/matrix" | jq 'max')"
version="$(sw_vers -productVersion)"
[[ "${version%%.*}" == "$latest" ]] || {
  echo "Benchmarks require macOS $latest; this Mac runs $version. Functional tests still support this runtime." >&2
  exit 1
}
