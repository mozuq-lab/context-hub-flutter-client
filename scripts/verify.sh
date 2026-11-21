#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init
test "$(git -C vendor/context-hub rev-parse HEAD)" = b762868caabc5e5e1fd1653097fd52197d10c438
npm ci --ignore-scripts
npm run build:protocol
flutter_bin="${FLUTTER_BIN:-flutter}"
"$flutter_bin" pub get
"$flutter_bin" analyze --no-pub
"$flutter_bin" test --no-pub
if [[ "$(uname -s)" == Darwin ]]; then
  python3 scripts/test_macos_snapshot.py
fi
