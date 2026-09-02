#!/usr/bin/env bash
set -euo pipefail

: "${CERTIFICATE_BASE64:?}"
: "${CERTIFICATE_PASSWORD:?}"
keychain="$RUNNER_TEMP/signing.keychain-db"
keychain_password="$(openssl rand -hex 16)"
certificate="$RUNNER_TEMP/certificate.p12"
installer_certificate="$RUNNER_TEMP/installer-certificate.p12"

echo "$CERTIFICATE_BASE64" | base64 --decode > "$certificate"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -P "$CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain"
if [ -n "${INSTALLER_CERTIFICATE_BASE64:-}" ]; then
  : "${INSTALLER_CERTIFICATE_PASSWORD:?}"
  echo "$INSTALLER_CERTIFICATE_BASE64" | base64 --decode > "$installer_certificate"
  security import "$installer_certificate" -P "$INSTALLER_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain"
fi
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain" login.keychain-db
rm -f "$certificate" "$installer_certificate"
security find-identity -v -p codesigning "$keychain"
