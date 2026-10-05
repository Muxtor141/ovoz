#!/usr/bin/env bash
# Regenerates the Dart <-> Swift bindings (D-02).
#
#  1. swiftc writes the Objective-C header for the engine's @objc API
#     (every Swift file except OvozPlugin.swift, which needs Flutter).
#  2. ffigen reads that header and writes the Dart bindings plus the
#     Objective-C trampolines Dart callbacks need (tool/ffigen.dart).
#
# Both outputs are committed; run this after changing an @objc declaration.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=ios/ovoz/Sources/ovoz
HEADER=ios/ovoz/Sources/ovoz_ffi/include/ovoz_objc_api.h
MODULE_CACHE=$(mktemp -d)
trap 'rm -rf "$MODULE_CACHE"' EXIT

mkdir -p "$(dirname "$HEADER")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
find "$SOURCES" -name '*.swift' ! -name 'OvozPlugin.swift' -print0 \
  | xargs -0 xcrun --sdk iphoneos swiftc -parse-as-library -module-name ovoz \
      -sdk "$SDK" -target arm64-apple-ios15.0 -swift-version 5 \
      -emit-module -emit-module-path "$MODULE_CACHE/ovoz.swiftmodule" \
      -emit-objc-header-path "$HEADER"

dart run tool/ffigen.dart
dart format lib/src/platform/darwin/ovoz_bindings.g.dart > /dev/null
echo "Bindings regenerated."
