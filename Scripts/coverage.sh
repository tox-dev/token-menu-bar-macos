#!/usr/bin/env bash
# Runs the test suite with coverage and fails when any line in the Core or UI targets never executed.
set -euo pipefail

cd "$(dirname "$0")/.."

swift test --enable-code-coverage "$@"

bin_dir="$(swift build --show-bin-path)"
profdata="$(ls "$bin_dir"/codecov/*.profdata | head -1)"
bundle="$(find "$bin_dir" -name '*.xctest' -type d | head -1)"
binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
ignore='(\.build|Tests|Sources/TokenMenuBar/)'

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
