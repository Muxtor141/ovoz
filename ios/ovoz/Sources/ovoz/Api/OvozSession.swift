import AVFoundation
import Foundation

/// Session events, implemented in Dart.
@objc(OvozSessionListener)
public protocol OvozSessionListener: NSObjectProtocol {
  func onInterruption(_ began: Bool, shouldResume: Bool)
  /// Headphones were unplugged: audio is about to come out of the speaker.
  func onBecomingNoisy()
  /// [reason] is an `AVAudioSession.RouteChangeReason` raw value.
  func onRouteChanged(_ reason: Int)
  /// The system's media services restarted; players may need to reload.
  func onMediaServicesReset()
}

/// The app-wide audio session, configured from Dart (D-14).
///
/// Categories, modes and options travel as their Dart enum indices and option
/// bits, mapped here, so Dart never needs AVFoundation's string constants.
@objc(OvozSession)
public final class OvozSession: NSObject {
  @objc public static let shared = OvozSession()

  @objc public func setListener(_ listener: OvozSessionListener?) {
    assertMainThread()
    OvozSessionManager.shared.listener = listener
  }

  /// Returns nil on success, or why the configuration was refused.
  @objc public func configure(
    managed: Bool, category: Int, mode: Int, options: Int, routeSharingPolicy: Int,
    interruptionPolicy: Int, pauseOnBecomingNoisy: Bool, deactivateWhenIdle: Bool
  ) -> String? {
    assertMainThread()
    var config = OvozSessionManager.Config()
    config.managed = managed
    config.category = Self.categories[safe: category] ?? .playback
    config.mode = Self.modes[safe: mode] ?? .default
    config.options = Self.options(from: options)
    config.routeSharingPolicy = routeSharingPolicy == 1 ? .longFormAudio : .default
    config.interruptionPolicy = OvozSessionManager.InterruptionPolicy(rawValue: interruptionPolicy) ?? .pauseAndResume
    config.pauseOnBecomingNoisy = pauseOnBecomingNoisy
    config.deactivateWhenIdle = deactivateWhenIdle
    do {
      try OvozSessionManager.shared.configure(config)
      return nil
    } catch {
      return "\(error.localizedDescription) (\(error))"
    }
  }

  /// Returns nil on success, or the reason it failed (for example another
  /// app holding a non-mixable session).
  @objc public func setActive(_ active: Bool) -> String? {
    assertMainThread()
    do {
      try OvozSessionManager.shared.setActive(active)
      return nil
    } catch {
      return "\(error.localizedDescription) (\(error))"
    }
  }

  @objc public var hasAudioBackgroundMode: Bool { OvozSessionManager.hasAudioBackgroundMode }

  // Order matches Dart's `SessionCategory`, `SessionMode` and option bits.
  private static let categories: [AVAudioSession.Category] = [.playback, .ambient, .soloAmbient, .playAndRecord]
  private static let modes: [AVAudioSession.Mode] = [.default, .spokenAudio, .moviePlayback, .voicePrompt]

  private static func options(from bits: Int) -> AVAudioSession.CategoryOptions {
    var options: AVAudioSession.CategoryOptions = []
    let table: [AVAudioSession.CategoryOptions] = [
      .mixWithOthers, .duckOthers, .interruptSpokenAudioAndMixWithOthers,
      .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker, .allowBluetoothHFP,
    ]
    for (bit, option) in table.enumerated() where bits & (1 << bit) != 0 {
      options.insert(option)
    }
    return options
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
