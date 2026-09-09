#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
minimum="${1:?Pass the minimum rendered assertion count}"
shift
[[ "$minimum" =~ ^[0-9]+$ ]]
deferred=false
if [[ "${1:-}" == --capture-only ]]; then
  shift
  if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ||
    -z "${TOKEN_MENU_BAR_RENDER_ARTIFACTS:-}" ]]; then
    echo "Deferred render checks require a GitHub-hosted desktop and an artifact directory." >&2
    exit 1
  fi
  deferred=true
fi
if [[ -n "${TOKEN_MENU_BAR_RENDER_ARTIFACTS:-}" ]]; then
  mkdir -p "$TOKEN_MENU_BAR_RENDER_ARTIFACTS"
  render_directory="$(mktemp -d "$TOKEN_MENU_BAR_RENDER_ARTIFACTS/run.XXXXXX")"
else
  render_directory="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-render.XXXXXX")"
fi
status=0
TOKEN_MENU_BAR_RENDER_ARTIFACTS="$render_directory" "$@" || status=$?
if [[ "$deferred" == true ]]; then
  count="$(find "$render_directory" -type f -name '*.ocr.json' | wc -l)"
  if [[ "$count" -lt "$minimum" ]]; then
    echo "Expected at least $minimum rendered-text captures; found $count." >&2
    status=1
  fi
  echo "Rendered-text assertions require the CI Rendered text job."
else
  Scripts/check-rendered-text.sh "$render_directory" "$minimum" || status=1
  if [[ "$minimum" -ge 12 ]]; then
    Scripts/test-rendered-text.sh "$render_directory/verifier-present.png" || status=1
  fi
fi
if [[ "$status" == 0 && -z "${TOKEN_MENU_BAR_RENDER_ARTIFACTS:-}" ]]; then
  rm -rf "$render_directory"
else
  echo "Mock render artifacts: $render_directory"
fi
exit "$status"
