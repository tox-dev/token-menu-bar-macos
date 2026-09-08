#!/usr/bin/env bash
# Derives the version from git the way setuptools-scm does, so a build off any commit names the commit it came from.
#
#   on a tag, clean tree   v1.2.3            -> 1.2.3
#   five commits past it   v1.2.3-5-gabc123  -> 1.2.4.dev5+gabc123
#   with local edits                         -> 1.2.4.dev5+gabc123.d20260830
#
# --marketing prints the numeric part alone, which is all CFBundleShortVersionString accepts, and --build prints the
# commit count for CFBundleVersion, which has to increase with every submission.
set -euo pipefail

cd "$(dirname "$0")/.."

described="$(git describe --tags --long --dirty --match 'v[0-9]*' 2> /dev/null || true)"
if [ -n "$described" ]; then
  dirty=""
  case "$described" in
    *-dirty)
      dirty="yes"
      described="${described%-dirty}"
      ;;
  esac
  node="${described##*-}"
  rest="${described%-*}"
  distance="${rest##*-}"
  tag="${rest%-*}"
  base="${tag#v}"
else
  # No release yet, so every commit is a pre-release of the first one.
  dirty=""
  [ -z "$(git status --porcelain 2> /dev/null)" ] || dirty="yes"
  base="0.0.0"
  distance="$(git rev-list --count HEAD 2> /dev/null || echo 0)"
  node="g$(git rev-parse --short HEAD 2> /dev/null || echo unknown)"
fi

if [ "$distance" = "0" ] && [ -z "$dirty" ]; then
  marketing="$base"
  full="$base"
else
  major="${base%%.*}"
  patch="${base##*.}"
  minor="${base#*.}"
  minor="${minor%.*}"
  marketing="${major}.${minor}.$((patch + 1))"
  full="${marketing}.dev${distance}+${node}"
  [ -z "$dirty" ] || full="${full}.d$(date -u +%Y%m%d)"
fi

case "${1:---full}" in
  --marketing) echo "$marketing" ;;
  --build) git rev-list --count HEAD 2> /dev/null || echo 1 ;;
  --full) echo "$full" ;;
  *)
    echo "usage: version.sh [--full|--marketing|--build]" >&2
    exit 2
    ;;
esac
