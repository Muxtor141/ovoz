import AVFoundation
import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Commands the lock screen, Control Center, headsets and cars can send. The
/// raw values are shared with Dart's `MediaCommand`; as bit positions they
/// also form the set passed to `enableMediaControls`.
@objc(OvozRemoteCommand)
public enum OvozRemoteCommand: Int {
  case play = 0, pause, togglePlayPause, stop, next, previous, seek, skipForward, skipBackward, changeRate
}

/// What the Now Playing center shows for its owner.
struct NowPlayingSnapshot {
  let item: OvozItem
  /// Whether playback is wanted (true while buffering too).
  let isPlaying: Bool
  let duration: Double?
  let elapsed: Double
  let rate: Double
  let defaultRate: Double
  let queueIndex: Int
  let queueCount: Int
}

/// The process-wide Now Playing entry and remote commands, owned by at most
/// one player at a time (D-15, BG-02).
///
/// Commands are forwarded to the owner's Dart listener rather than acted on
/// here, so the app's rules (a hold, an advertisement) apply to a headset
/// button exactly as to a button in the app (BG-03 keeps them native in the
/// sense that they need no Dart code to be *received*; Dart decides what they
/// do).
final class NowPlayingCenter {
  static let shared = NowPlayingCenter()

  private weak var owner: OvozPlayer?
  private var registered: [(MPRemoteCommand, Any)] = []
  private var artwork: (uri: String, artwork: MPMediaItemArtwork?)?
  private var artworkTask: URLSessionDataTask?

  func claim(_ player: OvozPlayer, commands: Int, skipForward: Double, skipBackward: Double) {
    owner = player
    unregisterCommands()
    registerCommands(commands, skipForward: skipForward, skipBackward: skipBackward)
    update(from: player)
  }

  func release(_ player: OvozPlayer) {
    guard owner === player else { return }
    owner = nil
    unregisterCommands()
    artworkTask?.cancel()
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
  }

  /// Republishes [player]'s item and timing, if it is the owner. Elapsed time
  /// and rate are enough for the system to animate the progress bar between
  /// updates (BG-04).
  func update(from player: OvozPlayer) {
    guard owner === player else { return }
    let center = MPNowPlayingInfoCenter.default()
    guard let snapshot = player.nowPlayingSnapshot else {
      center.nowPlayingInfo = nil
      center.playbackState = .stopped
      return
    }
    let item = snapshot.item
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: item.title ?? "",
      MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
      MPNowPlayingInfoPropertyPlaybackRate: snapshot.rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.defaultRate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if let artist = item.artist { info[MPMediaItemPropertyArtist] = artist }
    if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
    if let duration = snapshot.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if snapshot.queueIndex >= 0, snapshot.queueCount > 0 {
      info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = snapshot.queueIndex
      info[MPNowPlayingInfoPropertyPlaybackQueueCount] = snapshot.queueCount
    }
    if let uri = item.artworkUri {
      if let cached = artwork, cached.uri == uri {
        if let image = cached.artwork { info[MPMediaItemPropertyArtwork] = image }
      } else {
        loadArtwork(uri, for: player)
      }
    }
    center.nowPlayingInfo = info
    // The system can infer this from the audio session, but says so outright
    // where it would not (the lock screen hides a "paused" app sooner).
    center.playbackState = snapshot.isPlaying ? .playing : .paused
  }

  // MARK: Commands

  private func registerCommands(_ commands: Int, skipForward: Double, skipBackward: Double) {
    let center = MPRemoteCommandCenter.shared()
    func enabled(_ command: OvozRemoteCommand) -> Bool { commands & (1 << command.rawValue) != 0 }
    func add(_ remote: MPRemoteCommand, _ command: OvozRemoteCommand,
             value: @escaping (MPRemoteCommandEvent) -> Double = { _ in 0 }) {
      remote.isEnabled = enabled(command)
      guard remote.isEnabled else { return }
      let target = remote.addTarget { [weak self] event in
        guard let owner = self?.owner else { return .noActionableNowPlayingItem }
        owner.remoteCommand(command, value: value(event))
        return .success
      }
      registered.append((remote, target))
    }

    add(center.playCommand, .play)
    add(center.pauseCommand, .pause)
    add(center.togglePlayPauseCommand, .togglePlayPause)
    add(center.stopCommand, .stop)
    add(center.nextTrackCommand, .next)
    add(center.previousTrackCommand, .previous)
    add(center.changePlaybackPositionCommand, .seek) { event in
      ((event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0) * 1000
    }
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
    add(center.skipForwardCommand, .skipForward) { _ in skipForward * 1000 }
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackward)]
    add(center.skipBackwardCommand, .skipBackward) { _ in skipBackward * 1000 }
    add(center.changePlaybackRateCommand, .changeRate) { event in
      Double((event as? MPChangePlaybackRateCommandEvent)?.playbackRate ?? 1)
    }
  }

  private func unregisterCommands() {
    for (command, target) in registered {
      command.removeTarget(target)
      command.isEnabled = false
    }
    registered.removeAll()
  }

  // MARK: Artwork

  private func loadArtwork(_ uri: String, for player: OvozPlayer) {
    #if canImport(UIKit)
    artworkTask?.cancel()
    artwork = (uri, nil)
    guard let url = URL(string: uri) else { return }
    let deliver: (UIImage?) -> Void = { [weak self, weak player] image in
      onMain {
        guard let self, let player, self.artwork?.uri == uri, let image else { return }
        self.artwork = (uri, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
        self.update(from: player)
      }
    }
    switch url.scheme?.lowercased() {
    case "file":
      deliver(UIImage(contentsOfFile: url.path))
    case "asset":
      deliver(OvozAssets.path(forAsset: String(url.path.drop(while: { $0 == "/" }))).flatMap(UIImage.init(contentsOfFile:)))
    case "http", "https":
      artworkTask = URLSession.shared.dataTask(with: url) { data, _, _ in
        deliver(data.flatMap(UIImage.init(data:)))
      }
      artworkTask?.resume()
    default:
      break
    }
    #endif
  }
}
