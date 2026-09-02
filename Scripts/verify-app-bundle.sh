#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: verify-app-bundle.sh <app> <distribution> <required|forbidden>}"
expected_distribution="${2:?usage: verify-app-bundle.sh <app> <distribution> <required|forbidden>}"
expected_updater="${3:?usage: verify-app-bundle.sh <app> <distribution> <required|forbidden>}"
[[ "$expected_updater" == "required" || "$expected_updater" == "forbidden" ]] || {
  echo "updater policy must be required or forbidden" >&2
  exit 1
}

plist="$app/Contents/Info.plist"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print:CFBundleExecutable' "$plist")"
executable="$app/Contents/MacOS/$executable_name"
actual_distribution="$(/usr/libexec/PlistBuddy -c 'Print:TMBDistribution' "$plist")"
[[ "$actual_distribution" == "$expected_distribution" ]] || {
  echo "expected $expected_distribution distribution, got $actual_distribution" >&2
  exit 1
}

mach_o_count=0
while IFS= read -r -d '' binary; do
  file -b "$binary" | grep -q 'Mach-O' || continue
  mach_o_count=$((mach_o_count + 1))
  architectures="$(lipo -archs "$binary")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
    echo "$binary is not universal arm64/x86_64: $architectures" >&2
    exit 1
  }
  xcrun dyld_info -validate_only "$binary"
done < <(find "$app" -type f -print0)
[[ "$mach_o_count" -gt 0 ]] || {
  echo "no Mach-O files found in $app" >&2
  exit 1
}

otool_dependencies="$(xcrun otool -L "$executable")"
dyld_dependencies="$(xcrun dyld_info -linked_dylibs "$executable")"
sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
if [[ "$expected_updater" == "required" ]]; then
  [[ -d "$sparkle_framework" ]] || {
    echo "Direct build does not embed Sparkle.framework" >&2
    exit 1
  }
  grep -q 'Sparkle.framework' <<< "$otool_dependencies" || {
    echo "Direct executable has no Sparkle load command" >&2
    exit 1
  }
  grep -q 'Sparkle.framework' <<< "$dyld_dependencies" || {
    echo "dyld does not report Sparkle as a Direct dependency" >&2
    exit 1
  }
  /usr/libexec/PlistBuddy -c 'Print:SUFeedURL' "$plist" > /dev/null
  public_key="$(/usr/libexec/PlistBuddy -c 'Print:SUPublicEDKey' "$plist")"
  [[ -n "$public_key" && "$public_key" != *"\$("* ]] || {
    echo "Direct build has an empty or unexpanded SUPublicEDKey" >&2
    exit 1
  }
  /usr/libexec/PlistBuddy -c 'Print:SUEnableInstallerLauncherService' "$plist" > /dev/null
else
  [[ ! -e "$sparkle_framework" ]] || {
    echo "Sparkle.framework is embedded in $expected_distribution" >&2
    exit 1
  }
  ! grep -q 'Sparkle.framework' <<< "$otool_dependencies" || {
    echo "$expected_distribution executable retains a Sparkle load command" >&2
    exit 1
  }
  ! grep -q 'Sparkle.framework' <<< "$dyld_dependencies" || {
    echo "dyld reports Sparkle as a $expected_distribution dependency" >&2
    exit 1
  }
  for key in SUFeedURL SUPublicEDKey SUEnableInstallerLauncherService; do
    if /usr/libexec/PlistBuddy -c "Print:$key" "$plist" > /dev/null 2>&1; then
      echo "$key remains in $expected_distribution metadata" >&2
      exit 1
    fi
  done
fi

echo "verified $expected_distribution app: universal, dyld-valid, updater=$expected_updater"
