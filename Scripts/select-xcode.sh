#!/usr/bin/env bash
set -euo pipefail

newest=""
newest_major=0
newest_minor=0
newest_patch=0
exact="${EXACT_XCODE_MAJOR:-}"
for app in /Applications/Xcode*.app; do
  [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ] || continue
  version="$("$app/Contents/Developer/usr/bin/xcodebuild" -version)"
  number="${version%%$'\n'*}"
  number="${number#Xcode }"
  IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$number"
  candidate_minor="${candidate_minor:-0}"
  candidate_patch="${candidate_patch:-0}"
  if [ -n "$exact" ] && [ "$candidate_major" -ne "$exact" ]; then
    continue
  fi
  if [ "$candidate_major" -gt "$newest_major" ] ||
    { [ "$candidate_major" -eq "$newest_major" ] && [ "$candidate_minor" -gt "$newest_minor" ]; } ||
    { [ "$candidate_major" -eq "$newest_major" ] && [ "$candidate_minor" -eq "$newest_minor" ] &&
      [ "$candidate_patch" -gt "$newest_patch" ]; }; then
    newest="$app"
    newest_major="$candidate_major"
    newest_minor="$candidate_minor"
    newest_patch="$candidate_patch"
  fi
done
if [ -z "$newest" ]; then
  echo "No matching Xcode in /Applications${exact:+ for major $exact}" >&2
  exit 1
fi
# Switching needs root, which a laptop has no terminal for here, so only do it when it would change something.
if [ "$(xcode-select -p 2> /dev/null)" != "$newest/Contents/Developer" ]; then
  sudo xcode-select -s "$newest/Contents/Developer"
fi

# `xcodebuild -version | head -1` kills xcodebuild with a broken pipe, so read it whole and cut afterwards.
versions="$(xcodebuild -version)"
major="${versions%%$'\n'*}"
major="${major#Xcode }"
major="${major%%.*}"
minimum="${MIN_XCODE_MAJOR:-26}"
if [ "$major" -lt "$minimum" ]; then
  echo "Xcode ${major} is older than the required ${minimum}" >&2
  exit 1
fi
if [ -n "$exact" ] && [ "$major" -ne "$exact" ]; then
  echo "Xcode ${major} does not match the required major ${exact}" >&2
  exit 1
fi
echo "$versions"
swift --version
