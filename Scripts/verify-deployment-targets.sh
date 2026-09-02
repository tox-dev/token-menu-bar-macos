#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: verify-deployment-targets.sh <app> [maximum-version]}"
maximum="${2:-14.0}"
[[ -d "$app" ]] || {
  echo "missing application bundle: $app" >&2
  exit 1
}

checked=0
while IFS= read -r -d '' candidate; do
  file "$candidate" | grep -q 'Mach-O' || continue
  checked=$((checked + 1))
  min_versions="$(xcrun vtool -show-build "$candidate" | awk '$1 == "minos" { print $2 }')"
  [[ -n "$min_versions" ]] || {
    echo "missing LC_BUILD_VERSION in $candidate" >&2
    exit 1
  }
  while IFS= read -r minimum; do
    if ! awk -v minimum="$minimum" -v maximum="$maximum" 'BEGIN {
      split(minimum, a, "."); split(maximum, b, ".")
      exit (a[1] < b[1] || (a[1] == b[1] && a[2] <= b[2])) ? 0 : 1
    }'; then
      echo "$candidate requires macOS $minimum, above $maximum" >&2
      exit 1
    fi
  done <<< "$min_versions"
done < <(find "$app" -type f -print0)

[[ "$checked" -gt 0 ]] || {
  echo "no Mach-O files found in $app" >&2
  exit 1
}
echo "verified $checked Mach-O files at macOS $maximum or earlier"
