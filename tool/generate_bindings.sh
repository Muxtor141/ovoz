#!/usr/bin/env bash
# Regenerates the Dart <-> native bindings.
#
#   tool/generate_bindings.sh          both
#   tool/generate_bindings.sh ios      Dart <-> Swift (D-02)
#   tool/generate_bindings.sh android  Dart <-> Kotlin (D-19)
#
# iOS:
#  1. swiftc writes the Objective-C header for the engine's @objc API
#     (every Swift file except OvozPlugin.swift, which needs Flutter).
#  2. ffigen reads that header and writes the Dart bindings plus the
#     Objective-C trampolines Dart callbacks need (tool/ffigen.dart).
#
# Android:
#  1. The example app's Gradle build compiles the engine's Kotlin classes.
#  2. jnigen reads them and writes the Dart bindings (tool/jnigen.dart).
#
# The outputs are committed; run this after changing an @objc declaration or
# the Kotlin engine's public API (the classes in tool/jnigen.dart).
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM=${1:-all}

ios() {
  local sources=ios/ovoz/Sources/ovoz
  local header=ios/ovoz/Sources/ovoz_ffi/include/ovoz_objc_api.h
  local module_cache
  module_cache=$(mktemp -d)
  trap 'rm -rf "$module_cache"' RETURN

  mkdir -p "$(dirname "$header")"
  local sdk
  sdk=$(xcrun --sdk iphoneos --show-sdk-path)
  find "$sources" -name '*.swift' ! -name 'OvozPlugin.swift' -print0 \
    | xargs -0 xcrun --sdk iphoneos swiftc -parse-as-library -module-name ovoz \
        -sdk "$sdk" -target arm64-apple-ios15.0 -swift-version 5 \
        -emit-module -emit-module-path "$module_cache/ovoz.swiftmodule" \
        -emit-objc-header-path "$header"

  dart run tool/ffigen.dart
  dart format lib/src/platform/darwin/ovoz_bindings.g.dart > /dev/null
  echo "iOS bindings regenerated."
}

android() {
  (cd example && flutter pub get > /dev/null)
  (cd example/android && ./gradlew --quiet :ovoz:compileDebugKotlin)
  dart run tool/jnigen.dart 2> /dev/null
  dart format lib/src/platform/android/ovoz_bindings.g.dart > /dev/null
  echo "Android bindings regenerated."
}

case "$PLATFORM" in
  ios) ios ;;
  android) android ;;
  all) ios && android ;;
  *) echo "usage: $0 [ios|android]" >&2; exit 64 ;;
esac
