import AVFoundation
import Foundation

/// Turns Flutter asset keys into file paths. Installed by `OvozPlugin`, the
/// one file that may import Flutter, so the engine itself builds without it.
enum OvozAssets {
  static var lookupKey: ((String) -> String)?

  static func path(forAsset key: String) -> String? {
    guard let lookupKey else { return nil }
    return Bundle.main.path(forResource: lookupKey(key), ofType: nil)
  }
}

/// An [OvozItem] made playable: its asset, its `AVPlayerItem`, and the
/// resource loader that feeds an encrypted one (retained here, because
/// AVFoundation only keeps a weak reference to it, IO-03).
final class LoadedItem {
  let descriptor: OvozItem
  let playerItem: AVPlayerItem
  private let loader: DecryptingResourceLoader?

  let clipStart: CMTime
  let clipEnd: CMTime?

  /// Where to put the playhead once the item can seek; nil once applied. The
  /// player holds playback back until then, so the item never sounds from the
  /// wrong place.
  var pendingStart: CMTime?

  /// The loader's diagnosis of a failure, more precise than AVFoundation's.
  var loaderFailure: OvozError?

  /// Set when the item failed; it stays in the window so the state is clear.
  var failed = false

  /// Where the item was when it failed: its pending start if it never got
  /// there. A failed item reports this as its position, so that it is resumed
  /// from there, not from zero.
  var failedAt: CMTime?

  var id: Int64 { descriptor.itemId }

  private init(descriptor: OvozItem, playerItem: AVPlayerItem, loader: DecryptingResourceLoader?) {
    self.descriptor = descriptor
    self.playerItem = playerItem
    self.loader = loader
    clipStart = CMTime(milliseconds: max(0, descriptor.clipStartMs))
    clipEnd = descriptor.clipEndMs >= 0 ? CMTime(milliseconds: descriptor.clipEndMs) : nil
  }

  /// Builds the item, or explains why it cannot be built. A missing local
  /// file fails here, at once, rather than as an opaque error from
  /// AVFoundation later (it can take seconds).
  static func make(_ descriptor: OvozItem, pitch: AVAudioTimePitchAlgorithm,
                   onLoaderFailure: @escaping (Int64, OvozError) -> Void) -> Result<LoadedItem, OvozError> {
    guard let url = URL(string: descriptor.uri), let scheme = url.scheme?.lowercased() else {
      return .failure(OvozError(code: .invalidConfiguration, message: "Not a URI: \(descriptor.uri)"))
    }

    let location: Location
    switch scheme {
    case "file":
      guard FileManager.default.fileExists(atPath: url.path) else {
        return .failure(OvozError(code: .sourceNotFound, message: "No file at \(url.path)"))
      }
      location = .file(url.path)
    case "asset":
      let key = String(url.path.drop(while: { $0 == "/" }))
      guard let path = OvozAssets.path(forAsset: key) else {
        return .failure(OvozError(code: .sourceNotFound, message: "No Flutter asset \(key)"))
      }
      location = .file(path)
    case "http", "https":
      location = .remote(url)
    default:
      return .failure(OvozError(code: .invalidConfiguration, message: "Unsupported scheme in \(descriptor.uri)"))
    }

    let asset: AVURLAsset
    var loader: DecryptingResourceLoader?
    if let layout = descriptor.encryption {
      guard let name = descriptor.format, let format = AudioFormatInfo.named(name) else {
        return .failure(OvozError(code: .invalidConfiguration,
                                  message: "Encrypted sources must declare a supported format (mp3, aac, m4a, wav, aiff, flac, caf); got \(descriptor.format ?? "none")"))
      }
      let queue = DispatchQueue(label: "uz.sayma.ovoz.loader.\(descriptor.itemId)")
      let source: ByteSource
      switch location {
      case .file(let path): source = FileByteSource(path: path, queue: queue)
      case .remote(let url): source = HttpByteSource(url: url, headers: descriptor.headers, queue: queue)
      }
      let itemId = descriptor.itemId
      let made = DecryptingResourceLoader(source: source, layout: layout, format: format, queue: queue,
                                          onFailure: { onLoaderFailure(itemId, $0) })
      asset = AVURLAsset(url: DecryptingResourceLoader.url(itemId: itemId, format: format))
      asset.resourceLoader.setDelegate(made, queue: queue)
      loader = made
    } else {
      switch location {
      case .file(let path):
        asset = AVURLAsset(url: URL(fileURLWithPath: path))
      case .remote(let url):
        // AVURLAssetHTTPHeaderFieldsKey covers HLS playlists, keys and
        // segments, which a resource loader cannot (it never sees segments).
        // video_player has relied on it for years.
        let options: [String: Any]? = descriptor.headers.isEmpty
          ? nil : ["AVURLAssetHTTPHeaderFieldsKey": descriptor.headers]
        asset = AVURLAsset(url: url, options: options)
      }
    }

    let playerItem = AVPlayerItem(asset: asset)
    playerItem.audioTimePitchAlgorithm = pitch
    let item = LoadedItem(descriptor: descriptor, playerItem: playerItem, loader: loader)
    if let end = item.clipEnd { playerItem.forwardPlaybackEndTime = end }
    return .success(item)
  }

  private enum Location {
    case file(String)
    case remote(URL)
  }

  // MARK: Time, relative to the clip

  /// The item's own length, clipped; nil while unknown or for live streams.
  var duration: CMTime? {
    let full = playerItem.duration
    guard full.isNumeric, full.seconds > 0 else { return nil }
    let end = clipEnd.map { CMTimeMinimum($0, full) } ?? full
    let length = CMTimeSubtract(end, clipStart)
    return length.seconds > 0 ? length : .zero
  }

  func relative(_ time: CMTime) -> CMTime {
    guard time.isNumeric else { return .zero }
    let t = CMTimeSubtract(time, clipStart)
    return t.seconds > 0 ? t : .zero
  }

  func absolute(_ time: CMTime) -> CMTime {
    CMTimeAdd(clipStart, time)
  }
}

extension CMTime {
  init(milliseconds: Int64) {
    self = CMTime(value: milliseconds, timescale: 1000)
  }

  var milliseconds: Int64 {
    guard isNumeric else { return 0 }
    return Int64((seconds * 1000).rounded())
  }
}
