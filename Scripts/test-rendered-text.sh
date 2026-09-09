#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
image="${1:?Pass the synthetic ALPHA BRAVO fixture}"
probe="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-ocr-probe.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
cp "$image" "$probe/sample.png"
jq -n '{contains:["ALPHA BRAVO"], excludes:[], suffix:null, matches:true}' > "$probe/sample.ocr.json"
Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result"
jq -n '{contains:["ALPHA BRAVO CHARLIE"], excludes:[], suffix:null, matches:true}' > "$probe/sample.ocr.json"
if Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result" 2>&1; then
  echo "OCR accepted a fixture with a missing word." >&2
  exit 1
fi
rg -q 'Rendered text failed:' "$probe/result"
jq -n '{contains:[], excludes:[], suffix:"ALPHA", matches:true}' > "$probe/sample.ocr.json"
if Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result" 2>&1; then
  echo "OCR accepted the wrong trailing text." >&2
  exit 1
fi
rg -q 'Rendered text failed:' "$probe/result"
echo "OCR verifier accepted complete text and rejected missing words and incorrect endings."
