#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init
test "$(git -C vendor/context-hub rev-parse HEAD)" = c6ca7a4de48fcdf6e8c5898d3501947294edbf6e
npm ci --ignore-scripts
npm run build:protocol
flutter_bin="${FLUTTER_BIN:-flutter}"
"$flutter_bin" pub get
"$flutter_bin" analyze --no-pub
"$flutter_bin" test --no-pub
if [[ "$(uname -s)" == Darwin ]]; then
  python3 scripts/test_macos_snapshot.py
fi
