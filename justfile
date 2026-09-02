# Every workflow in this repository. Run `just` to see them.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List the recipes
default:
    @just --list --unsorted

# Build the package
build: toolchain
    swift build

# Check the toolchain can build this app, and say what to fix when it cannot
toolchain:
    @Scripts/check-toolchain.sh

# Run the test suite
test *filter:
    Scripts/check-test-isolation.sh
    swift test {{ if filter == "" { "" } else { "--filter " + filter } }}

# Run the tests and fail if a line in Core or UI never executed
coverage:
    Scripts/coverage.sh

# Stream the app's unified log
logs:
    log stream --level info --style compact --predicate 'subsystem == "dev.tox.token-menu-bar"'

# Format Swift, Markdown and YAML in place
fmt:
    swift format -i -r Sources Tests
    pre-commit run mdformat --all-files || true
    pre-commit run yamlfmt --all-files || true

# Run every pre-commit hook over the whole tree
lint:
    pre-commit run --all-files

# Build, test with the coverage gate, and lint
check: toolchain build coverage lint

# Assemble an ad-hoc signed .app in dist/ for machines without Xcode
app *args: toolchain
    Scripts/bundle-dev.sh {{ args }}

# Assemble the .app and launch it with real provider data
run:
    Scripts/bundle-dev.sh --run

# Assemble the .app and launch it with isolated demo data
run-demo:
    Scripts/bundle-dev.sh --run-demo

# Build the app and install it into /Applications, replacing any copy already there
_install:
    Scripts/bundle-dev.sh
    osascript -e 'quit app "Token Menu Bar"' 2>/dev/null || true
    rm -rf "/Applications/Token Menu Bar.app"
    cp -R "dist/Token Menu Bar.app" /Applications/

# Install the app and launch it with real provider data
install: _install
    open -a "Token Menu Bar"

# Install the app and launch it with isolated demo data
install-demo: _install
    open -a "Token Menu Bar" --args --verify-ui

# Re-render the website screenshots from demo data
shots:
    Scripts/screenshots.sh

# Redraw App/Assets.xcassets from the icon the app draws in code
icons:
    #!/usr/bin/env bash
    set -euo pipefail
    set="App/Assets.xcassets/AppIcon.appiconset"
    rm -rf "$set" && mkdir -p "$set"
    swift run TokenMenuBar --export-icon "$set" >/dev/null
    python3 - "$set" <<'PYTHON'
    import json, pathlib, sys
    icons = pathlib.Path(sys.argv[1])
    images = [
        {"filename": f"icon_{size}x{size}{suffix}.png", "idiom": "mac", "scale": scale, "size": f"{size}x{size}"}
        for size in (16, 32, 128, 256, 512)
        for suffix, scale in (("", "1x"), ("@2x", "2x"))
    ]
    for file in icons.glob("*.png"):
        if file.name not in {image["filename"] for image in images}:
            file.unlink()
    (icons / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                                                    indent=2) + "\n")
    PYTHON
    python3 Scripts/optimize-png.py "$set"

# Build the website into website/public
site:
    hugo --source website --minify

# Serve the website with live reload
site-serve:
    hugo server --source website

# Build the website the way Read the Docs does, into the directory it serves
site-readthedocs:
    : "${READTHEDOCS_CANONICAL_URL:?}"
    : "${READTHEDOCS_OUTPUT:?}"
    mkdir -p "$READTHEDOCS_OUTPUT/html"
    hugo --source website --gc --minify --baseURL "$READTHEDOCS_CANONICAL_URL" \
      --destination "$READTHEDOCS_OUTPUT/html"

# Generate the Xcode project from App/project.yml
xcode:
    cd App && xcodegen generate

# Print the version git says this working tree is
version:
    @Scripts/version.sh

# Write a version into App/project.yml, deriving it from git when no tag is given
stamp tag="":
    Scripts/stamp-version.sh {{ tag }}

# Start a release: Prepare Release tags the commit, which triggers the build, the cask and the App Store upload
release bump="patch":
    gh workflow run "Prepare Release" --field bump={{ bump }}
    @echo "Watch it with: gh run watch \$(gh run list --workflow 'Prepare Release' --limit 1 --json databaseId -q '.[0].databaseId')"

# Archive and export the Developer ID build into dist/direct
build-direct:
    Scripts/build-direct.sh

# Archive and export the Homebrew build without Sparkle into dist/homebrew
build-homebrew:
    Scripts/build-homebrew.sh

# Archive the sandboxed build and upload it to App Store Connect
build-app-store:
    Scripts/build-app-store.sh

# Zip, package and checksum the Developer ID build
package tag:
    Scripts/package-direct.sh {{ tag }}

# Zip, package and checksum the Homebrew build
package-homebrew tag:
    Scripts/package-homebrew.sh {{ tag }}

# Notarize and staple everything in a directory
notarize directory="dist/direct":
    Scripts/notarize.sh {{ directory }}

# Import a base64 signing certificate into a temporary keychain (CI)
import-certificate:
    Scripts/import-certificate.sh

# Write the Sparkle appcast for a release
appcast tag:
    Scripts/appcast.sh {{ tag }}

# Point the Homebrew cask at a released DMG
cask tag dmg="dist/homebrew/TokenMenuBar-Homebrew.dmg":
    Scripts/update-cask.sh {{ tag }} {{ dmg }}
