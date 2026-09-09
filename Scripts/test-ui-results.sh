#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
bundle="${1:?usage: test-ui-results.sh <synthetic-xcresult>}"
probe="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-results-probe.XXXXXX")"
trap 'rm -rf "$probe"' EXIT

Scripts/export-ui-results.sh "$bundle" "$probe/export"
xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$probe/summary.json"
cmp "$probe/summary.json" "$probe/export/summary.json"
xcrun xcresulttool export attachments --path "$bundle" --output-path "$probe/reference" > "$probe/attachments.log"
for directory in "$probe/reference" "$probe/export/attachments"; do
  rg --files --hidden --null "$directory" --glob '!manifest.json' |
    xargs -0 shasum -a 256 | cut -d ' ' -f 1 | sort > "$directory.sha256"
  jq -S 'map(.attachments |= map(del(.exportedFileName)))' "$directory/manifest.json" > "$directory.manifest.json"
done
cmp "$probe/reference.sha256" "$probe/export/attachments.sha256"
cmp "$probe/reference.manifest.json" "$probe/export/attachments.manifest.json"
expected="$(jq '[.. | objects | select(.nodeType? == "Test Case")] | length' "$probe/export/tests.json")"
details=("$probe/export"/test-*-details.json)
activities=("$probe/export"/test-*-activities.json)
[[ "$expected" -gt 0 && "${#details[@]}" == "$expected" && "${#activities[@]}" == "$expected" ]]
jq -e . "${details[@]}" "${activities[@]}" > /dev/null

index=0
while IFS= read -r identifier; do
  ((index += 1))
  if jq -e '.hasPerformanceMetrics' "$probe/export/test-$index-details.json" > /dev/null; then
    xcrun xcresulttool export metrics --path "$bundle" --test-id "$identifier" \
      --output-path "$probe/reference-metrics-$index" > "$probe/reference-metrics-$index.log"
    diff -r "$probe/reference-metrics-$index" "$probe/export/test-$index-metrics"
  else
    [[ ! -e "$probe/export/test-$index-metrics" ]]
  fi
done < <(jq -r '.. | objects | select(.nodeType? == "Test Case") | .nodeIdentifier' "$probe/export/tests.json")

if Scripts/export-ui-results.sh "$bundle" "$probe/export" > "$probe/reused" 2>&1; then
  echo "Result export overwrote existing evidence." >&2
  exit 1
fi
cmp "$probe/summary.json" "$probe/export/summary.json"
if Scripts/export-ui-results.sh "$probe/missing.xcresult" "$probe/missing" > "$probe/absent" 2>&1; then
  echo "Result export accepted a missing bundle." >&2
  exit 1
fi
[[ ! -e "$probe/missing" ]]
echo "Result export preserves test records and every attachment, and rejects reused or missing paths."
