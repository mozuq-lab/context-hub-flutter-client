#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_bin="${FLUTTER_BIN:-flutter}"
target="${1:-all}"
if [[ "$target" != all && "$target" != macos && "$target" != android ]]; then
  echo '使い方: scripts/build.sh [all|macos|android]' >&2; exit 2
fi
mkdir -p artifacts
if [[ "$target" == all || "$target" == android ]]; then
  mkdir -p .local-signing
  if [[ ! -f .local-signing/context-hub-test.jks ]]; then
    "${JAVA_HOME:+$JAVA_HOME/bin/}keytool" -genkeypair -noprompt -keystore .local-signing/context-hub-test.jks \
      -storepass android -keypass android -alias context-hub-local -keyalg RSA -keysize 3072 \
      -validity 3650 -dname 'CN=ContextHub Local Test' >/dev/null
    chmod 600 .local-signing/context-hub-test.jks
  fi
  "$flutter_bin" build apk --release
  cp build/app/outputs/flutter-apk/app-release.apk artifacts/context-hub-flutter-android.apk
fi
if [[ "$target" == all || "$target" == macos ]]; then
  "$flutter_bin" build macos --release
  ditto 'build/macos/Build/Products/Release/ContextHub Flutter.app' 'artifacts/ContextHub Flutter.app'
  codesign --verify --deep --strict 'artifacts/ContextHub Flutter.app'
fi
