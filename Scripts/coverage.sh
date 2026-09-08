#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

source Scripts/check-test-desktop.sh
Scripts/check-test-isolation.sh

build_args=(--scratch-path .build)
if [[ "${1:-}" == --scratch-path ]]; then
  build_args=(--scratch-path "$2")
  shift 2
fi
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
# A profile left by an earlier filtered run merges into this one and hides lines the full suite covers.
rm -rf "$bin_dir/codecov"
# Provider actors still run concurrently inside serialized tests; their coverage increments must not race.
swift test "${build_args[@]}" --enable-code-coverage --no-parallel \
  -Xswiftc -Xllvm -Xswiftc -instrprof-atomic-counter-update-all "$@"

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

live_calls="$(
  xcrun llvm-cov export "$binary" -instr-profile "$profdata" | jq '
    [.data[].functions[] | select(.count > 0) |
      select((.filenames[0] | test("/(SystemKeychain|SystemHTTPTransport|PersistentDefaults|ApplicationActivation)\\.swift$")) or
        ((.filenames[0] | endswith("/LibprocProcessScanner.swift")) and
          (.name | test("processes|listeningPorts|procargs"))))] | length'
)"
if ((live_calls > 0)); then
  echo "test isolation failed: $live_calls live credential, HTTP, preference, activation, or process-boundary functions ran" >&2
  exit 1
fi
echo "test isolation passed: no live credential, HTTP, preference, activation, or process-boundary calls"

# These files need a running host, a version-bound framework, or xcodebuild. The gate caps their size so logic cannot
# accumulate where the package tests cannot reach it. This array also supplies the SwiftPM coverage exclusions below.
glue=(
  Sources/TokenMenuBar/main.swift Sources/TokenMenuBarUI/WorkspaceGlue.swift
  Sources/TokenMenuBarUI/Adapters/LaunchAtLoginService.swift
  Sources/TokenMenuBarUI/Adapters/ApplicationActivation.swift
  Sources/TokenMenuBarUI/Adapters/PanelMaterialAdapter.swift
  Sources/TokenMenuBarUI/Adapters/NotificationCenterGlue.swift
  Sources/TokenMenuBarCore/Credentials/SystemKeychain.swift Sources/TokenMenuBarCore/PersistentDefaults.swift
  Sources/TokenMenuBarCore/HTTP/SystemHTTPTransport.swift
  Sources/TokenMenuBarCore/Providers/Antigravity/LibprocProcessScanner.swift
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
  while IFS= read -r file; do
    echo "$file"
    xcrun llvm-cov show "$binary" -instr-profile "$profdata" -use-color=false "$file" |
      awk '/^[[:space:]]*[0-9]+\|[[:space:]]*0\|/ { print }'
  done < <(
    jq -r '.data[].files[] | select(.summary.lines.covered < .summary.lines.count) | .filename' <<< "$summary"
  )
  exit 1
fi
echo "coverage gate passed: every line in Core and UI executed"
Scripts/check-cached-test-guard.sh "${build_args[@]}"
