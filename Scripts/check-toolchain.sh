#!/usr/bin/env bash
# Diagnoses a toolchain that cannot build this app, and says how to fix it. Changes nothing and never asks for root:
# `just build` on the wrong toolchain otherwise fails with a raw compiler error that names no cause.
set -euo pipefail

cd "$(dirname "$0")/.."

required="$(grep -oE '\.macOS\(\.v[0-9]+\)' Package.swift | grep -oE '[0-9]+' | head -1)"
problems=0

note() {
  echo "$1" >&2
  problems=$((problems + 1))
}

developer_dir="$(xcode-select -p 2> /dev/null || echo "")"
case "$developer_dir" in
  *CommandLineTools*)
    note "xcode-select points at $developer_dir, which cannot build an app bundle.
  Fix: sudo xcode-select --switch /Applications/Xcode.app"
    ;;
  "")
    note "No developer directory is selected.
  Fix: install Xcode, then sudo xcode-select --switch /Applications/Xcode.app"
    ;;
esac

host="$(sw_vers -productVersion)"
if [ "${host%%.*}" -lt "$required" ]; then
  note "This Mac runs macOS $host and the app targets macOS $required or newer, so it cannot run what it builds."
fi

if [ -x "$developer_dir/usr/bin/xcodebuild" ] || command -v xcodebuild > /dev/null 2>&1; then
  # `xcodebuild -version | head -1` closes the pipe and kills xcodebuild, so read it whole and cut afterwards.
  if versions="$(xcodebuild -version 2> /dev/null)"; then
    xcode="${versions%%$'\n'*}"
    xcode="${xcode#Xcode }"
    if [ "${xcode%%.*}" -lt "$required" ]; then
      note "Xcode ${xcode%%.*} is too old for the macOS $required SDK. Install a newer Xcode."
    fi
  fi
fi

if swift_version="$(swift --version 2>&1)"; then
  sdk="$(echo "$swift_version" | grep -oE 'macosx[0-9]+' | grep -oE '[0-9]+' | head -1)"
  if [ -n "$sdk" ] && [ "$sdk" -lt "$required" ]; then
    note "The active Swift toolchain targets macosx$sdk, older than the macOS $required this app needs.
  Fix: point swiftly or xcode-select at a newer toolchain."
  fi
fi

if [ "$problems" -gt 0 ]; then
  echo "" >&2
  echo "$problems toolchain problem(s); see above." >&2
  exit 1
fi
echo "toolchain ok: $developer_dir, macOS $host host, targeting macOS $required"
