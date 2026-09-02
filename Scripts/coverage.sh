#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

Scripts/check-test-isolation.sh

# A profile left by an earlier filtered run merges into this one and hides lines the full suite covers.
rm -rf "$(swift build --show-bin-path)/codecov"
# Serially: running the suite in parallel drops counters, and the gate then reports a line as unexecuted that a
# test plainly runs. It cost several false failures before the cause was pinned down. `just test` stays parallel.
swift test --enable-code-coverage --no-parallel "$@"

bin_dir="$(swift build --show-bin-path)"
# swift-testing and XCTest each write their own raw profile, and taking whatever SwiftPM happened to merge has
# reported a line as unexecuted when only one of them was in it. Merge every raw profile that exists.
profdata="$bin_dir/codecov/merged.profdata"
raw=("$bin_dir"/codecov/*.profraw)
if [ ! -e "${raw[0]}" ]; then
  echo "no coverage profiles under $bin_dir/codecov" >&2
  exit 1
fi
xcrun llvm-profdata merge -sparse "${raw[@]}" -o "$profdata"
bundle="$(find "$bin_dir" -name '*.xctest' -type d | head -1)"
binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"

# These files need a running host, a version-bound framework, or xcodebuild. The gate caps their size so logic cannot
# accumulate where the package tests cannot reach it. This array also supplies the SwiftPM coverage exclusions below.
glue=(
  Sources/TokenMenuBar/main.swift Sources/TokenMenuBarUI/WorkspaceGlue.swift
  Sources/TokenMenuBarUI/Adapters/LaunchAtLoginService.swift
  Sources/TokenMenuBarUI/Adapters/PanelMaterialAdapter.swift
  Sources/TokenMenuBarCore/Credentials/SystemKeychain.swift
  Sources/TokenMenuBarCore/HTTP/SystemHTTPTransport.swift
  Sources/TokenMenuBarWidgets/WidgetKitGlue.swift App/Sources/SparkleUpdater.swift
  App/Widget/Sources/WidgetBundle.swift
)
budget=40
ignore='(\.build|Tests'
for file in "${glue[@]}"; do
  lines="$(grep -cE '^[[:space:]]*[a-zA-Z@#}]' "$file")"
  if ((lines > budget)); then
    echo "$file has $lines lines of code; unmeasured glue must stay under $budget. Move the logic into Core or UI."
    exit 1
  fi
  echo "unmeasured glue: $file ($lines lines, capped at $budget)"
  if [[ "$file" == Sources/* ]]; then
    ignore+="|${file//./\.}"
  fi
done
ignore+=')'

report="$(
  xcrun llvm-cov report "$binary" -instr-profile "$profdata" -ignore-filename-regex="$ignore" -use-color=false
)"
echo "$report"
summary="$(
  xcrun llvm-cov export "$binary" -instr-profile "$profdata" -ignore-filename-regex="$ignore" -summary-only
)"
missed="$(jq '[.data[].files[].summary.lines | .count - .covered] | add // 0' <<< "$summary")"

if ((missed > 0)); then
  echo "lines never executed: $missed"
  jq -r '
    .data[].files[]
    | select(.summary.lines.covered < .summary.lines.count)
    | "\(.filename): \(.summary.lines.count - .summary.lines.covered)"
  ' <<< "$summary"
  exit 1
fi
echo "coverage gate passed: every line in Core and UI executed"
