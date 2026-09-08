#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
probe="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-ui-inventory-probe.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
mkdir -p "$probe/App/UITests" "$probe/App/Benchmarks" "$probe/.github" "$probe/Scripts"
cp App/UITests/*UITests.swift "$probe/App/UITests/"
cp App/Benchmarks/*.swift "$probe/App/Benchmarks/"
cp Scripts/check-ui-test-inventory.sh "$probe/Scripts/"
cp .github/ui-test-groups.json "$probe/.github/"
bash "$probe/Scripts/check-ui-test-inventory.sh"
while IFS= read -r group; do
  UI_GROUP="$group" bash "$probe/Scripts/check-ui-test-inventory.sh"
done < <(jq -r 'keys[]' .github/ui-test-groups.json)
while IFS=$'\t' read -r group method; do
  UI_GROUP="$group" UI_TEST="$method" bash "$probe/Scripts/check-ui-test-inventory.sh"
done < <(jq -r 'to_entries[] | .key as $group | .value[] | [$group, .] | @tsv' .github/ui-test-groups.json)
for group in '' usage lifecycle; do
  if UI_GROUP="$group" UI_TEST=LiveControlAuditUITests/testHistoryDatesAndControlsRespond \
    bash "$probe/Scripts/check-ui-test-inventory.sh" > "$probe/result" 2>&1; then
    echo "UI inventory accepted a method outside its diagnostic group: $group" >&2
    exit 1
  fi
done
if UI_GROUP=lifecycle UI_TEST=Unknown/testMissing \
  bash "$probe/Scripts/check-ui-test-inventory.sh" > "$probe/result" 2>&1; then
  echo "UI inventory accepted an unknown diagnostic method" >&2
  exit 1
fi
if UI_GROUP=missing-group bash "$probe/Scripts/check-ui-test-inventory.sh" > "$probe/result" 2>&1; then
  echo "UI inventory accepted an unknown diagnostic group" >&2
  exit 1
fi
for mutation in 'del(.performance[0])' '.performance += [.performance[0]]' '.performance[0] = "Unknown/testMissing"' '.lifecycle += [.performance[0]] | .performance |= .[1:]'; do
  jq "$mutation" .github/ui-test-groups.json > "$probe/.github/ui-test-groups.json"
  if bash "$probe/Scripts/check-ui-test-inventory.sh" > "$probe/result" 2>&1; then
    echo "UI inventory accepted a missing, duplicate, or unknown test: $mutation" >&2
    exit 1
  fi
  grep -Eq '^[-+][^-+].*/test' "$probe/result"
done
echo "UI inventory rejected missing, duplicate, and unknown tests."
