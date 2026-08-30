# Every workflow in this repository. Run `just` to see them.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List the recipes
default:
    @just --list --unsorted

# Build the package
build:
    swift build

# Run the test suite
test *filter:
    swift test {{ if filter == "" { "" } else { "--filter " + filter } }}

# Run the tests and fail if a line in Core or UI never executed
coverage:
    Scripts/coverage.sh

# Format Swift, Markdown and YAML in place
fmt:
    swift-format format -i -r Sources Tests
    pre-commit run mdformat --all-files || true
    pre-commit run yamlfmt --all-files || true

# Run every pre-commit hook over the whole tree
lint:
    pre-commit run --all-files

# Build, test with the coverage gate, and lint
check: build coverage lint

# Assemble an ad-hoc signed .app in dist/ for machines without Xcode
app *args:
    Scripts/bundle-dev.sh {{ args }}

# Assemble the .app and launch it
run:
    Scripts/bundle-dev.sh --run

# Build the app and install it into /Applications, replacing any copy already there
install:
    Scripts/bundle-dev.sh
    osascript -e 'quit app "Token Menu Bar"' 2>/dev/null || true
    rm -rf "/Applications/Token Menu Bar.app"
    cp -R "dist/Token Menu Bar.app" /Applications/
    open -a "Token Menu Bar"

# Re-render the website screenshots from demo data
shots:
    Scripts/screenshots.sh

# Write the app icon set into the given directory
icons directory="dist/icons":
    swift run TokenMenuBar --export-icon {{ directory }}

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

# Write a release version into App/project.yml
version tag:
    Scripts/stamp-version.sh {{ tag }}

# Start a release: Prepare Release tags the commit, which triggers the build, the cask and the App Store upload
release bump="patch":
    gh workflow run "Prepare Release" --field bump={{ bump }}
    @echo "Watch it with: gh run watch \$(gh run list --workflow 'Prepare Release' --limit 1 --json databaseId -q '.[0].databaseId')"

# Archive and export the Developer ID build into dist/direct
build-direct:
    Scripts/build-direct.sh

# Archive the sandboxed build and upload it to App Store Connect
build-app-store:
    Scripts/build-app-store.sh

# Zip, package and checksum the Developer ID build
package tag:
    Scripts/package-direct.sh {{ tag }}

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
cask tag dmg="dist/direct/TokenMenuBar.dmg":
    Scripts/update-cask.sh {{ tag }} {{ dmg }}
