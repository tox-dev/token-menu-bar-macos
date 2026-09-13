#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
probe_directory="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-desktop-guard.XXXXXX")"
trap 'rm -rf "$probe_directory"' EXIT
source Scripts/profile-ui-tests.sh
for command in \
  '/fixture/Token Menu Bar.app/Contents/MacOS/TokenMenuBarDirect --verify-ui' \
  '/fixture/Token Menu Bar.app/Contents/MacOS/TokenMenuBarDirect --relaunched --verify-ui -detailedLogging YES'; do
  is_verification_command "$command"
done
for command in \
  '/fixture/TokenMenuBarDirect' \
  '/fixture/TokenMenuBarDirect --relaunched' \
  '/fixture/TokenMenuBarDirect --verify-ui-invalid' \
  '/fixture/AnotherApp --verify-ui'; do
  if is_verification_command "$command"; then
    echo "Profile guard accepted a non-verification command: $command" >&2
    exit 1
  fi
done
xcrun clang -Wall -Wextra -Werror Tests/TokenMenuBarNativeGuard/NativeDesktop.c \
  Tests/NativeDesktopGuardProbe/main.c -o "$probe_directory/probe"

reject() {
  if "$@" > "$probe_directory/stdout" 2> "$probe_directory/stderr"; then
    echo "Desktop guard unexpectedly accepted: $*" >&2
    exit 1
  fi
  [[ ! -s "$probe_directory/stdout" ]]
  grep -Eq 'require.*GitHub-hosted desktop' "$probe_directory/stderr"
}

clean=(env -u TOKEN_MENU_BAR_TEST_DESKTOP -u GITHUB_ACTIONS -u RUNNER_ENVIRONMENT)
reject "${clean[@]}" "$probe_directory/probe"
reject "${clean[@]}" TOKEN_MENU_BAR_COMPILE_NATIVE_TESTS=1 "$probe_directory/probe"
reject "${clean[@]}" TOKEN_MENU_BAR_TEST_DESKTOP=local-verification "$probe_directory/probe"
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

xcrun clang -Wall -Wextra -Werror -DTOKEN_MENU_BAR_APPLICATION_UI_TESTS=1 \
  Tests/TokenMenuBarNativeGuard/NativeDesktop.c Tests/NativeDesktopGuardProbe/main.c -o "$probe_directory/application-probe"
reject "${clean[@]}" "$probe_directory/application-probe"
"${clean[@]}" TOKEN_MENU_BAR_TEST_DESKTOP=local-verification \
  "$probe_directory/application-probe" > "$probe_directory/stdout"
[[ "$(< "$probe_directory/stdout")" == 'test body reached' ]]

reject "${clean[@]}" Scripts/with-test-desktop.sh "$probe_directory/probe"
reject "${clean[@]}" GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=self-hosted \
  Scripts/with-test-desktop.sh "$probe_directory/probe"
"${clean[@]}" GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted \
  Scripts/with-test-desktop.sh "$probe_directory/probe" > "$probe_directory/stdout"
[[ "$(< "$probe_directory/stdout")" == 'test body reached' ]]
reject "${clean[@]}" Scripts/coverage.sh
reject "${clean[@]}" Scripts/profile-ui-tests.sh "$probe_directory/probe"
reject "${clean[@]}" Scripts/with-ui-artifacts.sh "$probe_directory/probe"
reject "${clean[@]}" Scripts/install-ocr.sh
reject "${clean[@]}" Scripts/with-render-checks.sh 12 --capture-only "$probe_directory/probe"
reject "${clean[@]}" GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=self-hosted \
  Scripts/with-render-checks.sh 12 --capture-only "$probe_directory/probe"
reject "${clean[@]}" Scripts/check-cached-test-guard.sh
reject "${clean[@]}" just test-native

echo "Desktop guard passed: native tests reject local execution before the test body"
