import AVFoundation
import Foundation

/// The app-wide audio session (D-14, SES-01…SES-09).
///
/// Players never configure the session themselves: they tell the manager when
/// they are about to play, and it applies the app's configuration then
/// (lazily: nothing touches the session until the first play, SES-09) and
/// activates it. It also turns system events — interruptions, headphones
/// unplugged — into the configured player behaviour, so every player reacts the
/// same way.
final class OvozSessionManager {
  static let shared = OvozSessionManager()

  struct Config {
    /// False: the app manages the session itself (SES-07). The manager then
    /// only observes, so player state stays correct.
    var managed = true
    var category: AVAudioSession.Category = .playback
    var mode: AVAudioSession.Mode = .default
    var options: AVAudioSession.CategoryOptions = []
    var routeSharingPolicy: AVAudioSession.RouteSharingPolicy = .default
    var interruptionPolicy = InterruptionPolicy.pauseAndResume
    var pauseOnBecomingNoisy = true
    var deactivateWhenIdle = false
  }

  /// SES-04. Raw values are shared with Dart.
  enum InterruptionPolicy: Int {
    /// Pause, and resume when the system says the interruption allows it.
    case pauseAndResume = 0
    /// Pause and stay paused.
    case pauseOnly = 1
    /// Leave it to the app (players still record that the system paused them).
    case none = 2
  }

  private(set) var config = Config()
  private var applied = false
  private var active = false
  private let players = NSHashTable<OvozPlayer>.weakObjects()
  private var interrupted: [OvozPlayer] = []
  private var deactivation: DispatchWorkItem?
  var listener: OvozSessionListener?

  private init() {
    #if os(iOS)
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    center.addObserver(self, selector: #selector(interruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: session)
    center.addObserver(self, selector: #selector(routeChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: session)
    center.addObserver(self, selector: #selector(mediaServicesReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: session)
    #endif
  }

  func register(_ player: OvozPlayer) { players.add(player) }

  func unregister(_ player: OvozPlayer) {
    players.remove(player)
    interrupted.removeAll { $0 === player }
    playerStateChanged()
  }

  // MARK: Configuration

  /// Applies [config] now if the session is already in use, otherwise at the
  /// next play. Runtime changes are allowed (SES-06).
  func configure(_ config: Config) throws {
    self.config = config
    applied = false
    if config.managed, active || players.allObjects.contains(where: \.isPlaying) {
      try apply()
    }
  }

  func setActive(_ value: Bool) throws {
    #if os(iOS)
    if value {
      if config.managed, !applied { try apply() }
      try AVAudioSession.sharedInstance().setActive(true)
    } else {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    active = value
    #endif
  }

  private func apply() throws {
    #if os(iOS)
    try AVAudioSession.sharedInstance().setCategory(config.category, mode: config.mode,
                                                    policy: config.routeSharingPolicy, options: config.options)
    applied = true
    #endif
  }

  // MARK: Called by players

  /// A player is about to start: configure and activate the session if the
  /// package manages it (SES-05).
  func playerWillPlay() {
    deactivation?.cancel()
    deactivation = nil
    guard config.managed else { return }
    do {
      if !applied { try apply() }
      if !active { try setActive(true) }
    } catch {
      NSLog("ovoz: could not activate the audio session: %@", "\(error)")
    }
  }

  /// Deactivates the session once nothing plays, when configured to, so other
  /// apps' audio can resume (SES-05).
  func playerStateChanged() {
    guard config.managed, config.deactivateWhenIdle, active else { return }
    guard !players.allObjects.contains(where: \.isPlaying) else {
      deactivation?.cancel()
      deactivation = nil
      return
    }
    guard deactivation == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.deactivation = nil
      guard !self.players.allObjects.contains(where: \.isPlaying) else { return }
      try? self.setActive(false)
    }
    deactivation = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
  }

  // MARK: System events

  #if os(iOS)
  @objc private func interruption(_ notification: Notification) {
    guard let info = notification.userInfo,
          let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
      .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
    onMain { [self] in
      switch type {
      case .began:
        active = false
        // The system has already silenced every player; record which ones
        // were playing so the state they report is true, and so they can be
        // resumed.
        interrupted = players.allObjects.filter { $0.interruptionBegan() }
        listener?.onInterruption(true, shouldResume: false)
      case .ended:
        let resume = interrupted
        interrupted = []
        if config.interruptionPolicy == .pauseAndResume, shouldResume {
          resume.forEach { $0.play() }
        }
        listener?.onInterruption(false, shouldResume: shouldResume)
      @unknown default:
        break
      }
    }
  }

  @objc private func routeChange(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
    onMain { [self] in
      if reason == .oldDeviceUnavailable {
        // Headphones unplugged: audio would come out of the speaker (BG-05).
        // AVFoundation pauses on its own; keep the players' state in line.
        let playing = players.allObjects.filter(\.isPlaying)
        if config.pauseOnBecomingNoisy {
          playing.forEach { $0.pause() }
        } else {
          playing.forEach { $0.resumeAfterRouteChange() }
        }
        listener?.onBecomingNoisy()
      }
      listener?.onRouteChanged(Int(reason.rawValue))
    }
  }

  @objc private func mediaServicesReset(_ notification: Notification) {
    onMain { [self] in
      applied = false
      active = false
      listener?.onMediaServicesReset()
    }
  }
  #endif

  /// Whether the app declares the `audio` background mode (BG-06, D-16).
  static var hasAudioBackgroundMode: Bool {
    (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("audio") ?? false
  }
}
