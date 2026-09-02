#!/usr/bin/env bash
# Refreshes the website screenshots. The app renders them itself on demo data, so a shot never depends on how
# crowded this machine's menu bar is, what sits behind the popover, or which display the popover opened on.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${OUT_DIR:-website/assets/images}"
binary="${APP_BINARY:-dist/Token Menu Bar.app/Contents/MacOS/TokenMenuBar}"

# Always rebuild unless a binary was named explicitly: reusing whatever is in dist/ meant every screenshot after a
# UI change silently showed the previous build.
if [[ -z "${APP_BINARY:-}" ]]; then
  echo "building the app bundle first" >&2
  CONFIGURATION=release Scripts/bundle-dev.sh > /dev/null
fi
if [[ ! -x "$binary" ]]; then
  echo "no app binary at $binary" >&2
  exit 1
fi

if ! command -v cwebp > /dev/null; then
  echo "cwebp is missing: brew install webp" >&2
  exit 1
fi

mkdir -p "$out"
"$binary" --export-menubar "$out"
"$binary" --export-popover "$out"

# The app draws PNG, the site serves WebP, and the repository keeps only what the site serves.
for shot in "$out"/*.png; do
  cwebp -quiet -q 92 -alpha_q 100 "$shot" -o "${shot%.png}.webp"
  rm "$shot"
done

echo "screenshots written to $out"
ls -la "$out"
