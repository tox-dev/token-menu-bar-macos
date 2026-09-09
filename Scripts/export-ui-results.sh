#!/usr/bin/env bash
set -euo pipefail

bundle="${1:?usage: export-ui-results.sh <xcresult> <new-output-directory>}"
output="${2:?usage: export-ui-results.sh <xcresult> <new-output-directory>}"
[[ -d "$bundle" && ! -e "$output" ]] || {
  echo "Result bundle must exist and output directory must be new." >&2
  exit 1
}
mkdir -p "$output"
xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$output/summary.json"
xcrun xcresulttool get test-results tests --path "$bundle" --compact > "$output/tests.json"
xcrun xcresulttool export attachments --path "$bundle" --output-path "$output/attachments" \
  > "$output/attachments.log"
xcrun xcresulttool export metrics --path "$bundle" --output-path "$output/metrics" \
  > "$output/metrics.log"

identifiers="$(jq -r '.. | objects | select(.nodeType? == "Test Case") | .nodeIdentifierURL' "$output/tests.json")"
index=0
while IFS= read -r identifier; do
  [[ -n "$identifier" ]] || continue
  ((index += 1))
  xcrun xcresulttool get test-results test-details --path "$bundle" --compact --test-id "$identifier" \
    > "$output/test-$index-details.json"
  xcrun xcresulttool get test-results activities --path "$bundle" --compact --test-id "$identifier" \
    > "$output/test-$index-activities.json"
done <<< "$identifiers"
echo "Exported $index test records with all attachments, activities and metrics."
du -sk "$bundle" "$output"
