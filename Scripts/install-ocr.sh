#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/check-test-desktop.sh

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1

snapshot="$(mktemp -d "${RUNNER_TEMP:?}/token-menu-bar-homebrew.XXXXXX")"
core="$(brew --repository)/Library/Taps/homebrew/homebrew-core"
restore_core() {
  if [[ -d "$snapshot/installed" && -e "$core" ]]; then
    mv "$core" "$snapshot/installed/core" || return
  fi
  if [[ -e "$snapshot/original" ]]; then mv "$snapshot/original" "$core" || return; fi
  rm -rf "$snapshot"
}
trap restore_core EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git init "$snapshot/core"
git -C "$snapshot/core" fetch --depth 1 https://github.com/Homebrew/homebrew-core.git 77f4bb7e8aa136e72360b5ad90c2b51968689d4e
git -C "$snapshot/core" checkout --detach FETCH_HEAD
mkdir -p "$(dirname "$core")"
# Hosted images can contain edited formulae; restore that tree after the pinned install.
if [[ -e "$core" ]]; then mv "$core" "$snapshot/original"; fi
mkdir "$snapshot/installed"
mv "$snapshot/core" "$core"
brew install --force-bottle tesseract
version="$(tesseract --version)"
[[ "${version%%$'\n'*}" == 'tesseract 5.5.3' ]]
data="$(brew --prefix tesseract)/share/tessdata/eng.traineddata"
[[ "$(shasum -a 256 "$data" | cut -d ' ' -f 1)" == 7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2 ]]
echo "$version" >> "$GITHUB_STEP_SUMMARY"
