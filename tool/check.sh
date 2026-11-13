#!/usr/bin/env bash
set -euo pipefail
python3 -m unittest discover -s tool/tests
flutter analyze
flutter test
