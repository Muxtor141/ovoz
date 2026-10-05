import Foundation

/// What Dart asks a player to play: a cheap descriptor, turned into an
/// `AVPlayerItem` only when it enters the player's window (D-04, PL-07).
///
/// [itemId] is chosen by Dart and is new every time an item is handed over,
/// even for the same source, so events always say which instance they are
/// about (a looped item is a new instance each lap).
@objc(OvozItem)
public final class OvozItem: NSObject {
  @objc public let itemId: Int64

  /// `file:///…`, `asset:///<flutter asset key>`, `http(s)://…`.
  @objc public let uri: String

  /// Declared container format (`mp3`, `m4a`, …). Required for encrypted
  /// sources, which AVFoundation cannot sniff.
  @objc public var format: String?

  /// Clip bounds in milliseconds; `clipEndMs < 0` plays to the end.
  @objc public var clipStartMs: Int64 = 0
  @objc public var clipEndMs: Int64 = -1

  // Now Playing metadata.
  @objc public var title: String?
  @objc public var artist: String?
  @objc public var album: String?
  @objc public var artworkUri: String?
  /// Length to show before the player has measured it; < 0 when unknown.
  @objc public var durationHintMs: Int64 = -1

  private(set) var headers: [String: String] = [:]
  private(set) var encryption: EncryptionLayout?

  @objc public init(itemId: Int64, uri: String) {
    self.itemId = itemId
    self.uri = uri
  }

  /// Sent with every HTTP request for this item.
  @objc public func addHeader(_ name: String, value: String) {
    headers[name] = value
  }

  /// Decrypts the source with AES-CTR. With [ivInHeader] the IV is read from
  /// the first 16 bytes of the file and [iv] is ignored. [dataOffset] is where
  /// the ciphertext starts.
  @objc public func setAesCtr(key: Data, iv: Data, ivInHeader: Bool, dataOffset: Int64) {
    encryption = EncryptionLayout(key: SecureBytes(key), iv: ivInHeader ? nil : iv, dataOffset: dataOffset)
  }

  override public var description: String { "OvozItem(\(itemId), \(uri))" }
}
