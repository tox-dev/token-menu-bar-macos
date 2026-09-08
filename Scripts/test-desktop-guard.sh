#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
probe_directory="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-desktop-guard.XXXXXX")"
trap 'rm -rf "$probe_directory"' EXIT
xcrun clang -Wall -Wextra -Werror Tests/TokenMenuBarNativeGuard/NativeDesktop.c \
  Tests/NativeDesktopGuardProbe/main.c -o "$probe_directory/probe"

reject() {
  if "$@" > "$probe_directory/stdout" 2> "$probe_directory/stderr"; then
    echo "Desktop guard unexpectedly accepted: $*" >&2
    exit 1
  fi
  [[ ! -s "$probe_directory/stdout" ]]
  rg -q 'require.*GitHub-hosted desktop' "$probe_directory/stderr"
}

clean=(env -u TOKEN_MENU_BAR_TEST_DESKTOP -u GITHUB_ACTIONS -u RUNNER_ENVIRONMENT)
reject "${clean[@]}" "$probe_directory/probe"
reject "${clean[@]}" TOKEN_MENU_BAR_TEST_DESKTOP=github-hosted "$probe_directory/probe"
reject "${clean[@]}" TOKEN_MENU_BAR_TEST_DESKTOP=github-hosted GITHUB_ACTIONS=true \
  RUNNER_ENVIRONMENT=self-hosted "$probe_directory/probe"
reject "${clean[@]}" TOKEN_MENU_BAR_TEST_DESKTOP=local GITHUB_ACTIONS=true \
  RUNNER_ENVIRONMENT=github-hosted "$probe_directory/probe"
reject "${clean[@]}" TOKEN_MENU_BAR_TEST_DESKTOP=github-hosted GITHUB_ACTIONS=false \
  RUNNER_ENVIRONMENT=github-hosted "$probe_directory/probe"
"${clean[@]}" TOKEN_MENU_BAR_TEST_DESKTOP=github-hosted GITHUB_ACTIONS=true \
  RUNNER_ENVIRONMENT=github-hosted "$probe_directory/probe" > "$probe_directory/stdout"
[[ "$(< "$probe_directory/stdout")" == 'test body reached' ]]

reject "${clean[@]}" Scripts/with-test-desktop.sh "$probe_directory/probe"
reject "${clean[@]}" GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=self-hosted \
  Scripts/with-test-desktop.sh "$probe_directory/probe"
"${clean[@]}" GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted \
  Scripts/with-test-desktop.sh "$probe_directory/probe" > "$probe_directory/stdout"
[[ "$(< "$probe_directory/stdout")" == 'test body reached' ]]
reject "${clean[@]}" Scripts/coverage.sh
reject "${clean[@]}" Scripts/profile-ui-tests.sh "$probe_directory/probe"
reject "${clean[@]}" Scripts/check-cached-test-guard.sh
reject "${clean[@]}" just test-native

echo "Desktop guard passed: native tests reject local execution before the test body"
