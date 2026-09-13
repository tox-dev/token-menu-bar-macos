#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
exec uv run Scripts/local_ui_tests.py "$@"
