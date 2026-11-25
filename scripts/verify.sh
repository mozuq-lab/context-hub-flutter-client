#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init
test "$(git -C vendor/context-hub rev-parse HEAD)" = ea3ca4a7736d24ca1afb6e1c512e2402c310e2d5
npm ci --ignore-scripts
npm run build:protocol
scripts/check_file_sizes.sh
flutter_bin="${FLUTTER_BIN:-flutter}"
"$flutter_bin" pub get
"$flutter_bin" analyze --no-pub
"$flutter_bin" test --no-pub
if [[ "$(uname -s)" == Darwin ]]; then
  python3 scripts/test_macos_snapshot.py
fi
