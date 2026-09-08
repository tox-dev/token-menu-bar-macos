#!/usr/bin/env bash
set -euo pipefail

is_verification_command() {
  [[ "$1 " == *'/TokenMenuBarDirect --verify-ui '* || "$1 " == *'/TokenMenuBarDirect --relaunched --verify-ui '* ]]
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return; fi

cd "$(dirname "$0")/.."
source Scripts/check-test-desktop.sh

profile_root="$HOME/Library/Containers/${UI_RUNNER_ID:-dev.tox.token-menu-bar.application-ui-tests.xctrunner}/Data/tmp"
mkdir -p "$profile_root"
profile_directory="$(mktemp -d "$profile_root/token-menu-bar-profile.XXXXXX")"

sample_verification() {
  shopt -s nullglob
  while true; do
    for profile_request in "$profile_directory"/*/request; do
      sample_directory="${profile_request%/request}"
      IFS= read -r profile_pid < "$profile_request"
      [[ "$profile_pid" =~ ^[1-9][0-9]*$ ]] || return 1
      profile_command="$(ps -p "$profile_pid" -o command=)"
      is_verification_command "$profile_command" || {
        echo "Refusing to sample a process outside the verification app" >&2
        return 1
      }
      /usr/bin/sample "$profile_pid" "${TMB_PROFILE_SAMPLE_SECONDS:-15}" 1 -file "$sample_directory/sample.pending" \
        > "$sample_directory/sampler.log" 2>&1
      mv "$profile_request" "$sample_directory/request.completed"
      mv "$sample_directory/sample.pending" "$sample_directory/sample.txt"
    done
    sleep 1
  done
}

sample_verification &
profile_monitor=$!
trap 'kill "$profile_monitor" 2>/dev/null || true; wait "$profile_monitor" 2>/dev/null || true; ditto "$profile_directory" .build/ui-profiles' EXIT
echo "CPU profile directory: $profile_directory"
TEST_RUNNER_TMB_PROFILE_DIRECTORY="$profile_directory" "$@"
