#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init
test "$(git -C vendor/context-hub rev-parse HEAD)" = f7f4cdfc97630d81e89e9e32274bc93ce0726cd6
npm ci --ignore-scripts
npm run build:protocol
flutter_bin="${FLUTTER_BIN:-flutter}"
"$flutter_bin" pub get
"$flutter_bin" analyze --no-pub
"$flutter_bin" test --no-pub
if [[ "$(uname -s)" == Darwin ]]; then
  python3 scripts/test_macos_snapshot.py
fi
