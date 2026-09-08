#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/check-test-desktop.sh
exec "$@"
