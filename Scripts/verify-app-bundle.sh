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
self_update="$(/usr/libexec/PlistBuddy -c 'Print:TMBSelfUpdateEnabled' "$plist" 2> /dev/null || true)"
placeholder_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
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
  if [[ "$self_update" == "YES" ]]; then
    key_bytes="$(base64 --decode <<< "$public_key" 2> /dev/null | wc -c | tr -d ' ')"
    [[ "$key_bytes" -eq 32 && "$public_key" != "$placeholder_key" ]] || {
      echo "self-update is enabled but SUPublicEDKey is not a real EdDSA public key: $public_key" >&2
      exit 1
    }
  fi
  /usr/libexec/PlistBuddy -c 'Print:SUEnableInstallerLauncherService' "$plist" > /dev/null
else
  [[ "$self_update" != "YES" ]] || {
    echo "self-update is enabled in $expected_distribution metadata" >&2
    exit 1
  }
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

signature_info="$(codesign -dv --verbose=4 "$app" 2>&1 || true)"
team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<< "$signature_info" | head -1)"
signing_check=ad-hoc
if [[ -n "$team_identifier" && "$team_identifier" != "not set" ]]; then
  signing_check=distribution
  if [[ "$expected_distribution" == "App Store" ]]; then
    expected_group="group.dev.tox.token-menu-bar"
    expected_app_sandbox=true
  else
    expected_group="${team_identifier}.dev.tox.token-menu-bar"
    expected_app_sandbox=false
    while IFS= read -r -d '' bundle; do
      bundle_signature="$(codesign -dv --verbose=4 "$bundle" 2>&1)"
      grep -Eq 'flags=.*\([^)]*runtime[^)]*\)' <<< "$bundle_signature" || {
        echo "$bundle is missing the hardened-runtime signature flag" >&2
        exit 1
      }
      codesign --verify --strict --verbose=2 "$bundle"
    done < <(find "$app" -type d \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' -o -name '*.framework' \) -print0)
  fi

  entitlements="$(mktemp)"
  trap 'rm -f "$entitlements"' EXIT
  for bundle in "$app" "$app/Contents/PlugIns/TokenMenuBarWidget.appex"; do
    [[ -d "$bundle" ]] || {
      echo "missing signed bundle: $bundle" >&2
      exit 1
    }
    codesign -d --entitlements - --xml "$bundle" > "$entitlements" 2> /dev/null
    actual_group="$(plutil -extract 'com\.apple\.security\.application-groups.0' raw -o - "$entitlements")"
    [[ "$actual_group" == "$expected_group" ]] || {
      echo "$bundle uses app group $actual_group; expected $expected_group" >&2
      exit 1
    }
    configured_group="$(/usr/libexec/PlistBuddy -c 'Print:TokenMenuBarAppGroup' "$bundle/Contents/Info.plist")"
    [[ "$configured_group" == "$expected_group" ]] || {
      echo "$bundle metadata uses app group $configured_group; expected $expected_group" >&2
      exit 1
    }
    actual_sandbox="$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$entitlements" 2> /dev/null || echo false)"
    if [[ "$bundle" == *.appex ]]; then
      expected_sandbox=true
    else
      expected_sandbox="$expected_app_sandbox"
    fi
    [[ "$actual_sandbox" == "$expected_sandbox" ]] || {
      echo "$bundle sandbox=$actual_sandbox; expected $expected_sandbox" >&2
      exit 1
    }
  done
  rm -f "$entitlements"
  trap - EXIT
fi

echo "verified $expected_distribution app: universal, dyld-valid, updater=$expected_updater, signing=$signing_check"
