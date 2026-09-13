#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: verify-build-settings.sh <target> <configuration> <distribution> <condition> <sandbox> <entitlements>}"
configuration="${2:?usage: verify-build-settings.sh <target> <configuration> <distribution> <condition> <sandbox> <entitlements>}"
distribution="${3:?usage: verify-build-settings.sh <target> <configuration> <distribution> <condition> <sandbox> <entitlements>}"
condition="${4:?usage: verify-build-settings.sh <target> <configuration> <distribution> <condition> <sandbox> <entitlements>}"
sandbox="${5:?usage: verify-build-settings.sh <target> <configuration> <distribution> <condition> <sandbox> <entitlements>}"
entitlements="${6:?usage: verify-build-settings.sh <target> <configuration> <distribution> <condition> <sandbox> <entitlements>}"

settings="$(xcodebuild -project App/TokenMenuBar.xcodeproj -target "$target" -configuration "$configuration" \
  -showBuildSettings)"

assert_setting() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' <<< "$settings")"
  [[ "$actual" == *"$expected"* ]] || {
    echo "$configuration: expected $key to contain '$expected', got '$actual'" >&2
    exit 1
  }
}

assert_setting TMB_DISTRIBUTION "$distribution"
assert_setting SWIFT_ACTIVE_COMPILATION_CONDITIONS "$condition"
assert_setting ENABLE_APP_SANDBOX "$sandbox"
assert_setting CODE_SIGN_ENTITLEMENTS "$entitlements"
