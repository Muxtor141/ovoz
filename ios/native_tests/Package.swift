// swift-tools-version: 5.9
// Tests for the engine's loader layer — cipher, byte sources, the decrypting
// resource loader — run on macOS with `swift test`, no simulator needed.
//
// Sources/OvozLoader holds symlinks to the plugin's own files, so these tests
// exercise exactly the code that ships.
import PackageDescription

let package = Package(
  name: "OvozNativeTests",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "OvozLoader", path: "Sources/OvozLoader"),
    .testTarget(
      name: "OvozLoaderTests",
      dependencies: ["OvozLoader"],
      path: "Tests/OvozLoaderTests",
      resources: [.copy("Fixtures")]
    ),
  ]
)
