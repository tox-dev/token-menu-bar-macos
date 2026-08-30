#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# A profile left by an earlier filtered run merges into this one and hides lines the full suite covers.
rm -rf "$(swift build --show-bin-path)/codecov"
swift test --enable-code-coverage "$@"

bin_dir="$(swift build --show-bin-path)"
profdata="$(ls "$bin_dir"/codecov/*.profdata | head -1)"
bundle="$(find "$bin_dir" -name '*.xctest' -type d | head -1)"
binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
ignore='(\.build|Tests|Sources/TokenMenuBar/|WorkspaceGlue\.swift|WidgetKitGlue\.swift)'

# These five files cannot be measured here: main.swift, WorkspaceGlue.swift and WidgetKitGlue.swift need a running
# app, a LaunchServices call or a WidgetKit host, and the two under App/ only compile under xcodebuild. The gate
# caps their size instead, so logic cannot accumulate where no test can reach it.
glue=(
  Sources/TokenMenuBar/main.swift Sources/TokenMenuBarUI/WorkspaceGlue.swift
  Sources/TokenMenuBarWidgets/WidgetKitGlue.swift App/Sources/SparkleUpdater.swift
  App/Widget/Sources/WidgetBundle.swift
)
budget=40
for file in "${glue[@]}"; do
  lines="$(grep -cE '^[[:space:]]*[a-zA-Z@#}]' "$file")"
  if ((lines > budget)); then
    echo "$file has $lines lines of code; unmeasured glue must stay under $budget. Move the logic into Core or UI."
    exit 1
  fi
  echo "unmeasured glue: $file ($lines lines, capped at $budget)"
done

xcrun llvm-cov report "$binary" -instr-profile "$profdata" -ignore-filename-regex="$ignore" -use-color=false

missed="$(
  xcrun llvm-cov show "$binary" -instr-profile "$profdata" -ignore-filename-regex="$ignore" -use-color=false \
    | awk '/^\/.*\.swift:$/ { file = $0; next } /^ +[0-9]+\| +0\|/ { print file " " $0 }'
)"

if [[ -n "$missed" ]]; then
  echo "lines never executed:"
  echo "$missed"
  exit 1
fi
echo "coverage gate passed: every line in Core and UI executed"
