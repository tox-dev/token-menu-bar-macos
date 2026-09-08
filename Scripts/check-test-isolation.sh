#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

reject_matches() {
  message="$1"
  pattern="$2"
  shift 2
  if matches="$(rg -n "$pattern" "$@")"; then
    echo "$message" >&2
    echo "$matches" >&2
    exit 1
  else
    status=$?
    if ((status != 1)); then
      echo "test isolation scan failed with status $status" >&2
      exit "$status"
    fi
  fi
}

reject_matches \
  "tests and benchmarks must use isolated credential, HTTP, notification, and login-item clients" \
  'SecItem(Add|CopyMatching|Delete|Update)|URLSession(\.shared|[[:space:]]*\()|SystemHTTPTransport\.make|KeychainCredentialClient\.system|keychain:[[:space:]]*\.system|LaunchAtLoginService\.backend|UNUserNotificationCenter\.current' \
  Tests App/UITests --glob '*.swift'
reject_matches \
  "tests must use TestDefaults, which never touches ~/Library/Preferences" \
  'UserDefaults[[:space:]]*\([[:space:]]*suiteName:' \
  Tests App/UITests --glob '*.swift'
reject_matches \
  "tests must inject process boundaries instead of launching subprocesses" \
  '\b(Process|LibprocProcessScanner)[[:space:]]*\(' Tests App/UITests --glob '*.swift'
reject_matches \
  "persistent preferences must use the injectable Core boundary" \
  'UserDefaults[[:space:]]*\([[:space:]]*suiteName:' \
  Sources --glob '*.swift' --glob '!PersistentDefaults.swift'

reject_matches \
  "native presentation tests belong in Tests/TokenMenuBarUITests/Native, excluded from local builds" \
  '\b(NSWindow|NSPanel|NSPopover|NSOpenPanel|NSSavePanel|NSAlert|NSWindowController|NSStatusBar|StatusItemController|LogWindowController|AppController|AppDelegate|DeferredAppDelegate|TooltipPanel|TooltipPresenter)[[:space:]]*\(|NSStatusBar\.system|\.(orderFrontRegardless|orderFront|orderBack|makeKeyAndOrderFront|showWindow|runModal|beginModalSession|activate)[[:space:]]*\(' \
  Tests --glob '*.swift' --glob '!**/Native/**'

global_mutation='method_exchangeImplementations|URLProtocol\.(registerClass|unregisterClass)|setClass\(|(NSApplication\.shared|NSApp|application)\.delegate[[:space:]]*='
if mutation_files="$(rg -l "$global_mutation" Tests App/UITests --glob '*.swift')"; then
  while IFS= read -r file; do
    if ! rg -q '@Suite\([.]serialized\)' "$file"; then
      echo "$file mutates process-global state outside a serialized suite" >&2
      rg -n "$global_mutation" "$file" >&2
      exit 1
    fi
  done <<< "$mutation_files"
else
  status=$?
  if ((status != 1)); then
    echo "test isolation scan failed with status $status" >&2
    exit "$status"
  fi
fi
