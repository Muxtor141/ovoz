import Flutter
import UIKit

/// Registers no method channel: Dart talks to the engine through FFI bindings.
///
/// The class exists for two things only Flutter can provide: it makes sure the
/// plugin is linked into the app (Dart finds the engine's classes by name in
/// the Objective-C runtime, so the linker must not strip them as unused), and
/// it tells the engine where Flutter keeps its assets. This is the only file
/// that imports Flutter, so the engine itself builds and tests without it.
public class OvozPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    _ = [OvozPlayer.self, OvozItem.self, OvozSession.self] as [AnyClass]
    OvozAssets.lookupKey = { FlutterDartProject.lookupKey(forAsset: $0) }
  }
}
