#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
uv venv --allow-existing --python 3.14 .build/verification-tools
uv pip install --python .build/verification-tools/bin/python \
  psutil==7.2.2 types-psutil==7.2.2.20260906 pytest==9.1.1 pytest-mock==3.15.1 pytest-cov==7.1.0 ty==0.0.80
.build/verification-tools/bin/ty check --python .build/verification-tools/bin/python \
  Scripts/local_ui_tests.py Scripts/tests/test_local_ui_tests.py
.build/verification-tools/bin/python -m pytest Scripts/tests/test_local_ui_tests.py -q --cov=Scripts --cov-report=
.build/verification-tools/bin/python -m coverage report \
  --include='Scripts/local_ui_tests.py,Scripts/tests/*' --fail-under=100 --show-missing
