#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/check-test-desktop.sh

profile_root="$HOME/Library/Containers/dev.tox.token-menu-bar.application-ui-tests.xctrunner/Data/tmp"
mkdir -p "$profile_root"
profile_directory="$(mktemp -d "$profile_root/token-menu-bar-profile.XXXXXX")"

sample_verification() {
  while [[ ! -f "$profile_directory/request" ]]; do sleep 1; done
  IFS= read -r profile_pid < "$profile_directory/request"
  [[ "$profile_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  profile_command="$(ps -p "$profile_pid" -o command=)"
  [[ "$profile_command" == *'/TokenMenuBarDirect --verify-ui'* ]] || {
    echo "Refusing to sample a process outside the verification app" >&2
    return 1
  }
  /usr/bin/sample "$profile_pid" 5 1 -file "$profile_directory/sample.pending" \
    > "$profile_directory/sampler.log" 2>&1
  mv "$profile_directory/sample.pending" "$profile_directory/sample.txt"
}

sample_verification &
profile_monitor=$!
trap 'kill "$profile_monitor" 2>/dev/null || true; wait "$profile_monitor" 2>/dev/null || true' EXIT
echo "CPU profile directory: $profile_directory"
TEST_RUNNER_TMB_PROFILE_DIRECTORY="$profile_directory" "$@"
