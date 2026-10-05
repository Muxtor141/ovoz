import AVFoundation
import Foundation

/// How an encrypted resource is laid out (ENC-03).
struct EncryptionLayout {
  let key: SecureBytes
  /// The IV, or nil when it is stored in the file's first 16 bytes.
  let iv: Data?
  /// Where the ciphertext starts: 0 for a bare file, 16 when the IV is the
  /// file's header, or wherever the app's own header ends.
  let dataOffset: Int64
}

/// Plays an encrypted resource by decrypting it in memory, inside the player
/// pipeline (D-06): AVFoundation asks this delegate for plaintext byte ranges,
/// the delegate reads the matching ciphertext from its [ByteSource] and
/// decrypts it on the way through. No localhost proxy, no decrypted copy on
/// disk.
///
/// Every delegate callback, byte-source callback and piece of state is on
/// [queue], so the loader needs no locks.
final class DecryptingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  static let scheme = "ovoz-enc"

  let queue: DispatchQueue
  private let source: ByteSource
  private let layout: EncryptionLayout
  private let format: AudioFormatInfo
  private let onFailure: (OvozError) -> Void

  private enum Phase {
    case idle
    case preparing
    case ready(plaintextLength: Int64, cipher: AesCtrCipher)
    case failed(OvozError)
  }

  private var phase = Phase.idle
  private var waiting: [AVAssetResourceLoadingRequest] = []

  /// Requests being served. AVFoundation does not keep a request alive once
  /// the delegate has taken it: the delegate owns it until it finishes it.
  private var active: [ObjectIdentifier: (request: AVAssetResourceLoadingRequest, read: ByteRead)] = [:]

  /// [onFailure] hears about the first failure that makes the resource
  /// unplayable (wrong key, unreachable server), which AVFoundation would
  /// otherwise report as an opaque "cannot open".
  init(source: ByteSource, layout: EncryptionLayout, format: AudioFormatInfo, queue: DispatchQueue,
       onFailure: @escaping (OvozError) -> Void) {
    self.source = source
    self.layout = layout
    self.format = format
    self.queue = queue
    self.onFailure = onFailure
  }

  deinit {
    source.close()
  }

  /// A URL in the loader's scheme; AVFoundation hands every request for it to
  /// this delegate. The extension is cosmetic: the declared UTI is what counts.
  static func url(itemId: Int64, format: AudioFormatInfo) -> URL {
    URL(string: "\(scheme)://item/\(itemId).\(format.name)")!
  }

  // MARK: AVAssetResourceLoaderDelegate

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                      shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    handle(loadingRequest)
    return true
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    // AVFoundation cancels requests it no longer needs, most often on a seek
    // or when it has buffered enough: stop reading for them at once.
    waiting.removeAll { $0 === loadingRequest }
    active.removeValue(forKey: ObjectIdentifier(loadingRequest))?.read.cancel()
  }

  private func handle(_ request: AVAssetResourceLoadingRequest) {
    switch phase {
    case .idle:
      waiting.append(request)
      prepare()
    case .preparing:
      waiting.append(request)
    case .ready(let length, let cipher):
      serve(request, plaintextLength: length, cipher: cipher)
    case .failed(let error):
      request.finishLoading(with: error.nsError)
    }
  }

  // MARK: Preparation: length, IV and the wrong-key check

  private func prepare() {
    phase = .preparing
    let ivInHeader = layout.iv == nil
    let headerLength = Int(layout.dataOffset) + AudioFormatInfo.signatureLength
    source.prepare(headerLength: headerLength) { [weak self] result in
      guard let self else { return }
      do {
        let (length, header) = try result.get()
        guard length >= layout.dataOffset else {
          throw OvozError(code: .decryption, message: "The file is shorter than its \(layout.dataOffset)-byte header")
        }
        let iv: Data
        if let explicit = layout.iv {
          iv = explicit
        } else if header.count >= AesCtrCipher.blockSize {
          iv = header.prefix(AesCtrCipher.blockSize)
        } else {
          throw OvozError(code: .decryption, message: "The file is too short to hold its IV")
        }
        let cipher = try AesCtrCipher(key: layout.key, iv: iv)
        let body = header.dropFirst(Int(layout.dataOffset))
        if !body.isEmpty {
          var plain = Data(body)
          cipher.apply(&plain, at: 0)
          if !format.matches(plain) {
            throw OvozError(
              code: .decryption,
              message: "Decrypted bytes do not start like a \(format.name) file: wrong key\(ivInHeader ? "" : " or IV"), or the format is not \(format.name)")
          }
        }
        phase = .ready(plaintextLength: length - layout.dataOffset, cipher: cipher)
      } catch {
        let failure = error as? OvozError ?? OvozError.from(error)
        phase = .failed(failure)
        onFailure(failure)
      }
      let pending = waiting
      waiting.removeAll()
      for request in pending where !request.isCancelled {
        handle(request)
      }
    }
  }

  // MARK: Serving

  private func serve(_ request: AVAssetResourceLoadingRequest, plaintextLength: Int64, cipher: AesCtrCipher) {
    if let info = request.contentInformationRequest {
      info.contentType = format.uti
      info.contentLength = plaintextLength
      info.isByteRangeAccessSupported = true
      // Without this, AVFoundation treats the custom scheme like a network
      // stream: it asks for everything to the end and keeps 30–50 MB of
      // decrypted audio in memory per item, whatever the file's size. On
      // demand, it reads 64 KB at a time, just before playing it, as it does
      // for a plain local file. (iOS 15 keeps the bounded prefetch.)
      if source.readsOnDemand, #available(iOS 16.0, macOS 13.0, *) {
        info.isEntireLengthAvailableOnDemand = true
      }
    }
    guard let dataRequest = request.dataRequest else {
      request.finishLoading()
      return
    }

    let start = dataRequest.currentOffset
    let end = dataRequest.requestsAllDataToEndOfResource
      ? plaintextLength
      : min(plaintextLength, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
    guard start < end else {
      request.finishLoading()
      return
    }

    var cursor = start
    let id = ObjectIdentifier(request)
    let read = source.read(
      offset: layout.dataOffset + start,
      count: end - start,
      onData: { data in
        guard !request.isCancelled, let dataRequest = request.dataRequest else { return false }
        var plain = data
        cipher.apply(&plain, at: cursor)
        cursor += Int64(plain.count)
        dataRequest.respond(with: plain)
        return true
      },
      onEnd: { [weak self] error in
        self?.active.removeValue(forKey: id)
        guard !request.isCancelled else { return }
        if let error {
          request.finishLoading(with: error.nsError)
          self?.onFailure(error)
        } else {
          request.finishLoading()
        }
      })
    active[id] = (request, read)
  }
}
