#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

scratch="$(mktemp -d "${TMPDIR:-/tmp}/token-menu-bar-docs.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/site"
cp website/hugo.toml "$scratch/site/"
cp -R website/content website/layouts website/assets website/static "$scratch/site/"
if [[ -d website/resources ]]; then cp -R website/resources "$scratch/site/"; fi

hugo --source "$scratch/site" --destination "$scratch/valid" \
  --baseURL https://example.invalid/en/preview/ --minify > "$scratch/build.log" 2>&1 || {
  cat "$scratch/build.log"
  exit 1
}
grep -q '/en/preview/start/connect/' "$scratch/valid/start/index.html"
grep -q '/en/preview/reference/settings/menu-bar/#custom-templates' "$scratch/valid/reference/menu-bar/index.html"
for provider in claude codex gemini antigravity cursor copilot; do
  grep -q "/en/preview/reference/providers/$provider/" "$scratch/valid/reference/providers/index.html"
  grep -q "/en/preview/reference/providers/$provider/" "$scratch/valid/index.html"
  test -s "$scratch/valid/reference/providers/$provider/index.md"
  grep -q 'Polling and network' "$scratch/valid/reference/providers/$provider/index.html"
done
grep -q '>Get started</a>' "$scratch/valid/index.html"
if grep -q 'Build from source</a>' "$scratch/valid/index.html"; then
  echo "The homepage promotes source builds over installation" >&2
  exit 1
fi
for section in about menu-bar providers data notifications log; do
  grep -q "/en/preview/reference/settings/$section/" "$scratch/valid/reference/settings/index.html"
done
test -s "$scratch/valid/reference/providers/index.md"
test -s "$scratch/valid/llms.txt"

printf '%s\n' '---' 'title: Link check' '---' '[Missing page](/missing-doc-page/)' \
  > "$scratch/site/content/link-check.md"
if hugo --source "$scratch/site" --destination "$scratch/invalid-link" > "$scratch/link.log" 2>&1; then
  echo "The site accepted a missing internal page" >&2
  exit 1
fi
grep -q 'Unresolved documentation link' "$scratch/link.log"

printf '%s\n' '---' 'title: Image check' '---' '{{< shot name="missing-doc-image" alt="Missing" >}}' \
  > "$scratch/site/content/link-check.md"
if hugo --source "$scratch/site" --destination "$scratch/invalid-image" > "$scratch/image.log" 2>&1; then
  echo "The site accepted a missing screenshot" >&2
  exit 1
fi
grep -q 'Missing screenshot images/missing-doc-image' "$scratch/image.log"
echo "Docs checks passed: versioned links, Markdown output, missing-page and missing-image failures"
