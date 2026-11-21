#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_bin="${FLUTTER_BIN:-flutter}"
target="${1:-all}"
case "$target" in
  all|macos|macos-signed|android) ;;
  *) echo '使い方: scripts/build.sh [all|macos|macos-signed|android]' >&2; exit 2 ;;
esac
macos_build_method="${MACOS_BUILD_METHOD:-workspace}"
if [[ "$target" != android ]]; then
  if [[ "$macos_build_method" != workspace && "$macos_build_method" != project ]]; then
    echo 'MACOS_BUILD_METHODはworkspaceまたはprojectを指定してください。' >&2; exit 2
  fi
fi
if [[ "$target" == macos-signed ]]; then
  signing_identity="${MACOS_SIGN_IDENTITY:-}"
  if [[ -z "$signing_identity" ]]; then
    echo 'MACOS_SIGN_IDENTITYに署名証明書の名前またはhashを指定してください。' >&2
    exit 2
  fi
  case "${MACOS_TIMESTAMP:-required}" in
    required) timestamp_option=--timestamp ;;
    none) timestamp_option=--timestamp=none ;;
    *) echo 'MACOS_TIMESTAMPはrequiredまたはnoneを指定してください。' >&2; exit 2 ;;
  esac
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
if [[ "$target" != android ]]; then
  if [[ "$macos_build_method" == project ]]; then
    "$flutter_bin" build macos --release --config-only
    build_dir="$PWD/build/macos"
    xcodebuild -project macos/Runner.xcodeproj -configuration Release -scheme Runner \
      -derivedDataPath "$build_dir" -destination 'platform=macOS,arch=arm64' \
      "OBJROOT=$build_dir/Build/Intermediates.noindex" \
      "SYMROOT=$build_dir/Build/Products" COMPILER_INDEX_STORE_ENABLE=NO \
      EXCLUDED_ARCHS=x86_64 -quiet
  else
    "$flutter_bin" build macos --release
  fi
  stage=$(mktemp -d artifacts/.macos-build.XXXXXX)
  previous_app="$stage/previous-app"
  # 復元にも失敗した場合は、以前のアプリを一時領域に残す。
  trap 'if [[ ! -e "$previous_app" && ! -L "$previous_app" ]]; then rm -rf -- "$stage"; fi' EXIT
  app_name='ContextHub Flutter.app'
  app_bundle="$stage/$app_name"
  archive_name=context-hub-flutter-macos.zip
  ditto "build/macos/Build/Products/Release/$app_name" "$app_bundle"

  if [[ "$target" == macos-signed ]]; then
    archive_name=context-hub-flutter-macos-developer-id.zip
    # 内側のframeworkから先に署名する。
    find "$app_bundle/Contents/Frameworks" -depth -type d -name '*.framework' -print0 > "$stage/frameworks"
    while IFS= read -r -d '' framework; do
      codesign --force --sign "$signing_identity" "$timestamp_option" "$framework"
    done < "$stage/frameworks"
    codesign --force --sign "$signing_identity" "$timestamp_option" --options runtime \
      --entitlements macos/Runner/Release.entitlements "$app_bundle"
  fi
  codesign --verify --deep --strict "$app_bundle"
  ditto -c -k --keepParent "$app_bundle" "$stage/$archive_name"

  # 検証とZIP作成が済んでから置き換え、古いappに新しいファイルを混ぜない。
  final_app="artifacts/$app_name"
  final_archive="artifacts/$archive_name"
  if [[ -d "$final_archive" ]]; then
    echo 'ZIPの出力先にディレクトリがあります。' >&2
    exit 1
  fi
  if [[ -e "$final_app" || -L "$final_app" ]]; then
    mv "$final_app" "$previous_app"
  fi
  if mv "$app_bundle" "$final_app"; then
    if mv -f "$stage/$archive_name" "$final_archive"; then
      rm -rf -- "$previous_app"
      exit 0
    fi
    mv "$final_app" "$app_bundle"
  fi
  if [[ -e "$previous_app" || -L "$previous_app" ]]; then
    mv "$previous_app" "$final_app"
  fi
  exit 1
fi
