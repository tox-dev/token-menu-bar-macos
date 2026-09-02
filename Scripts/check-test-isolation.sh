#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

forbidden='SecItem(Add|CopyMatching|Delete|Update)|URLSession(\.shared|[[:space:]]*\()|SystemHTTPTransport\.make|KeychainCredentialClient\.system|keychain:[[:space:]]*\.system|LaunchAtLoginService\.backend|UNUserNotificationCenter\.current'
if matches="$(rg -n "$forbidden" Tests App/UITests --glob '*.swift')"; then
  echo "tests and benchmarks must use isolated credential, HTTP, notification, and login-item clients" >&2
  echo "$matches" >&2
  exit 1
fi
