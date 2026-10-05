// swift-tools-version: 5.9
// Swift Package Manager build of the ovoz engine. CocoaPods builds the same
// sources through ../ovoz.podspec.

import PackageDescription

let package = Package(
  name: "ovoz",
  platforms: [
    .iOS("15.0"),
  ],
  products: [
    .library(name: "ovoz", targets: ["ovoz"]),
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "ovoz",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        "ovoz_ffi",
      ],
      resources: [
        .process("PrivacyInfo.xcprivacy"),
      ]
    ),
    // The Objective-C trampolines ffigen generates for Dart callbacks
    // (tool/generate_bindings.sh). A target of their own: a Swift package
    // target cannot mix Swift and Objective-C.
    .target(
      name: "ovoz_ffi",
      publicHeadersPath: "include"
    ),
  ]
)
