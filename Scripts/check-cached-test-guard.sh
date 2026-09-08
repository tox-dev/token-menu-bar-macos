#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/check-test-desktop.sh
test_bin_dir="$(swift build "$@" --show-bin-path)"
if [[ -d "$test_bin_dir/TokenMenuBarUITests.xctest" ]]; then
  native_product=TokenMenuBarUITests
elif [[ -d "$test_bin_dir/TokenMenuBarPackageTests.xctest" ]]; then
  native_product=TokenMenuBarPackageTests
else
  echo "No native UI test product under $test_bin_dir" >&2
  exit 1
fi
guard_directory="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-cached-guard.XXXXXX")"
trap 'rm -rf "$guard_directory"' EXIT

if env -u TOKEN_MENU_BAR_TEST_DESKTOP swift test "$@" --skip-build --no-parallel \
  --test-product "$native_product" --filter suppressedPopoverDoesNotPresentAWindowOrActivate \
  > "$guard_directory/output" 2>&1; then
  echo "A cached native test executable accepted a non-native invocation" >&2
  exit 1
fi
if ! rg -Fq 'Native AppKit tests require an isolated GitHub-hosted desktop' "$guard_directory/output"; then
  echo "The cached test executable failed without the expected desktop guard diagnostic" >&2
  sed -n '1,100p' "$guard_directory/output" >&2
  exit 1
fi
if rg -Fq '◇ Test run started.' "$guard_directory/output"; then
  echo "The desktop guard ran after the test framework started" >&2
  exit 1
fi
echo "Cached native executable rejected execution before the test framework started"
