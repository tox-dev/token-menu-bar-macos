#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
image="${1:?Pass the synthetic ALPHA BRAVO fixture}"
probe="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-ocr-probe.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
cp "$image" "$probe/sample.png"
jq -n '{contains:["ALPHA BRAVO"], excludes:[], suffix:null, matches:true}' > "$probe/sample.ocr.json"
if PATH=/usr/bin:/bin Scripts/check-rendered-text.sh "$probe" 1 > "$probe/missing-tool" 2>&1; then
  echo "Rendered assertions passed without an OCR engine." >&2
  exit 1
fi
grep -Fq 'Rendered-text verification requires Tesseract' "$probe/missing-tool"
Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result"
jq -n '{contains:["ALPHABRAVO"], excludes:[], suffix:null, matches:true}' > "$probe/sample.ocr.json"
Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result"
jq -n '{contains:["ALPHA BR AVO"], excludes:[], suffix:null, matches:true}' > "$probe/sample.ocr.json"
Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result"
jq -n '{contains:[], excludes:["ALPHABRAVO"], suffix:null, matches:true}' > "$probe/sample.ocr.json"
if Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result" 2>&1; then
  echo "OCR accepted excluded text with different whitespace." >&2
  exit 1
fi
grep -Fq 'Rendered text failed:' "$probe/result"
jq -n '{contains:["ALPHA BRAVO CHARLIE"], excludes:[], suffix:null, matches:true}' > "$probe/sample.ocr.json"
if Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result" 2>&1; then
  echo "OCR accepted a fixture with a missing word." >&2
  exit 1
fi
grep -Fq 'Rendered text failed:' "$probe/result"
jq -n '{contains:[], excludes:[], suffix:"ALPHA", matches:true, layout:"paragraph"}' > "$probe/sample.ocr.json"
if Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result" 2>&1; then
  echo "OCR accepted the wrong trailing text." >&2
  exit 1
fi
grep -Fq 'Rendered text failed:' "$probe/result"
jq -n '{contains:["ALPHA BRAVO"], excludes:[], suffix:null, matches:true, layout:"paragraph"}' > "$probe/sample.ocr.json"
Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result"
jq -n '{contains:["ALPHA BRAVO CHARLIE"], excludes:[], suffix:null, matches:true, layout:"paragraph"}' > "$probe/sample.ocr.json"
if Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result" 2>&1; then
  echo "Paragraph OCR accepted a fixture with a missing word." >&2
  exit 1
fi
grep -Fq 'Rendered text failed:' "$probe/result"
jq -n '{contains:["ALPHA BRAVO"], excludes:[], suffix:null, matches:true, layout:"unknown"}' > "$probe/sample.ocr.json"
if Scripts/check-rendered-text.sh "$probe" 1 > "$probe/result" 2>&1; then
  echo "OCR accepted an unknown page layout." >&2
  exit 1
fi
echo "OCR verifier accepted complete text and rejected missing words and incorrect endings."
