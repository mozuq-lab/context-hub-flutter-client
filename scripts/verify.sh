#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init
test "$(git -C vendor/context-hub rev-parse HEAD)" = 8f3203f83d59b5588a65e20f11367052ec87dd33
npm ci --ignore-scripts
npm run build:protocol
flutter_bin="${FLUTTER_BIN:-flutter}"
"$flutter_bin" pub get
"$flutter_bin" analyze --no-pub
"$flutter_bin" test --no-pub
if [[ "$(uname -s)" == Darwin ]]; then
  python3 scripts/test_macos_snapshot.py
fi
