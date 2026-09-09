#!/usr/bin/env bash
set -euo pipefail

artifact_directory="${1:?Pass the isolated render artifact directory}"
minimum="${2:-1}"
[[ "$minimum" =~ ^[0-9]+$ && -d "$artifact_directory" ]]
recognizer="$(command -v tesseract)" || {
  echo "Rendered-text verification requires Tesseract; no OCR assertions were executed." >&2
  exit 1
}
scratch="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-ocr.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
find "$artifact_directory" -type f -name '*.ocr.json' -print0 > "$scratch/manifest"
count=0
failed=0
while IFS= read -r -d '' expectation; do
  image="${expectation%.ocr.json}.png"
  [[ -f "$image" && ! -L "$image" ]]
  [[ "$(wc -c < "$image")" -le 33554432 ]]
  jq -e '
    (.contains | type == "array") and (.excludes | type == "array") and
    (.matches | type == "boolean") and
    ((.suffix == null) or (.suffix | type == "string")) and
    ((.contains | length) + (.excludes | length) + (.suffix // "" | length) > 0)
  ' "$expectation" > /dev/null
  OMP_THREAD_LIMIT=1 LC_ALL=C /usr/bin/perl -e 'alarm shift; exec @ARGV or die $!' \
    10 "$recognizer" "$image" stdout --psm 11 -l eng quiet > "$scratch/recognized"
  if ! jq -e --rawfile recognized "$scratch/recognized" '
    def words: ascii_downcase | [scan("[[:alnum:]]+")];
    . as $rule |
    ($recognized | gsub("\\s+"; " ")) as $text |
    ([.contains[] | . as $fragment | $text | contains($fragment)] | all) as $contains |
    ([.excludes[] | . as $fragment | $text | contains($fragment) | not] | all) as $excludes |
    (if .suffix == null then true else
      (.suffix | words) as $ending | ($recognized | words) as $actual |
      (($ending | length) > 0 and $actual[-($ending | length):] == $ending)
    end) as $suffix |
    (($contains and $excludes and $suffix) == $rule.matches)
  ' "$expectation" > /dev/null; then
    echo "Rendered text failed: $expectation" >&2
    sed -n '1,50p' "$scratch/recognized" >&2
    failed=$((failed + 1))
  fi
  count=$((count + 1))
done < "$scratch/manifest"
[[ "$count" -ge "$minimum" ]] || {
  echo "Expected at least $minimum rendered-text assertions; found $count." >&2
  exit 1
}
echo "Rendered-text assertions: $count; failures: $failed"
[[ "$failed" == 0 ]]
