#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
probe="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-capture-probe.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
mkdir "$probe/empty"
PATH=/usr/bin:/bin Scripts/check-rendered-text.sh "$probe/empty" 0 > "$probe/empty-output"
grep -Fxq 'Rendered-text assertions: 0; failures: 0' "$probe/empty-output"
if PATH=/usr/bin:/bin Scripts/check-rendered-text.sh "$probe/empty" 1 > "$probe/required" 2>&1; then
  echo "Empty capture accepted missing required assertions." >&2
  exit 1
fi
grep -Fq 'Expected at least 1 rendered-text assertions; found 0.' "$probe/required"
capture=(env GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted TOKEN_MENU_BAR_RENDER_ARTIFACTS="$probe")
"${capture[@]}" Scripts/with-render-checks.sh 1 --capture-only \
  bash > "$probe/success" << 'BASH'
touch "$TOKEN_MENU_BAR_RENDER_ARTIFACTS/sample.ocr.json"
echo 'Test run with 1 test passed after 0.001 seconds.'
BASH
grep -Fq 'require the CI Rendered text job' "$probe/success"
if "${capture[@]}" Scripts/with-render-checks.sh 1 --capture-only true > "$probe/missing" 2>&1; then
  echo "Deferred capture accepted missing assertions." >&2
  exit 1
fi
grep -Fq 'Expected at least 1 rendered-text captures; found 0.' "$probe/missing"
status=0
"${capture[@]}" Scripts/with-render-checks.sh 1 --capture-only \
  bash > "$probe/failure" 2>&1 << 'BASH' || status=$?
touch "$TOKEN_MENU_BAR_RENDER_ARTIFACTS/sample.ocr.json"
exit 7
BASH
[[ "$status" == 7 ]]
for outcome in empty interrupted zero failed restarted; do
  if "${capture[@]}" Scripts/with-render-checks.sh 1 --capture-only \
    bash -s "$outcome" > "$probe/$outcome-suite" 2>&1 << 'BASH'; then
touch "$TOKEN_MENU_BAR_RENDER_ARTIFACTS/sample.ocr.json"
case "$1" in
  empty) ;;
  interrupted) echo 'Test run started.'; echo 'Test fixture() started.' ;;
  zero) echo 'Test run with 0 tests passed after 0.001 seconds.' ;;
  failed) echo 'Test run with 1 test failed after 0.001 seconds.' ;;
  restarted) echo 'Test run with 1 test passed after 0.001 seconds.'; echo 'Test run started.' ;;
esac
BASH
    echo "Accepted a $outcome suite without successful completion." >&2
    exit 1
  fi
  grep -Fq 'exited without a completed, nonempty passing suite' "$probe/$outcome-suite"
done
for summary in '1 test' '2 tests' '2 tests in 1 suite' '3 tests in 2 suites' '1226 tests in 0 suites'; do
  Scripts/with-render-checks.sh 0 bash -s "$summary" > "$probe/immediate-success" << 'BASH'
echo "Test run with $1 passed after 0.001 seconds."
BASH
done
status=0
Scripts/with-render-checks.sh 0 bash > "$probe/exit-after-summary" 2>&1 << 'BASH' || status=$?
echo 'Test run with 2 tests passed after 0.001 seconds.'
exit 7
BASH
[[ "$status" == 7 ]]
echo "Deferred captures enforce fresh assertion counts and preserve command failures."
