import CommonCrypto
import Foundation

/// AES in CTR mode, decrypting from any byte offset (ENC-01, ENC-04).
///
/// The 16-byte IV is the first counter block, and the counter is the whole
/// block read as one 128-bit big-endian integer (ENC-02). That is what
/// PointyCastle (Dart's `encrypt` package) and OpenSSL do, and what Mutolaa's
/// files were written with.
///
/// The keystream is built here — counter blocks encrypted with AES-ECB — rather
/// than by CommonCrypto's CTR mode, so the counter arithmetic is ours and
/// cannot differ from the encryptor's.
///
/// Not thread-safe: each resource loader uses its own instance on its queue.
final class AesCtrCipher {
  static let blockSize = 16

  private let cryptor: CCCryptorRef
  private let ivHigh: UInt64
  private let ivLow: UInt64

  /// Reused between calls so steady-state decryption allocates nothing.
  private var counters = [UInt8]()
  private var keystream = [UInt8]()

  init(key: SecureBytes, iv: Data) throws {
    guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else {
      throw OvozError(code: .invalidConfiguration,
                      message: "AES key must be 16, 24 or 32 bytes, got \(key.count)")
    }
    guard iv.count == Self.blockSize else {
      throw OvozError(code: .invalidConfiguration, message: "AES-CTR IV must be 16 bytes, got \(iv.count)")
    }
    var ref: CCCryptorRef?
    let status = key.withUnsafeBytes { keyBytes in
      CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                      CCOptions(kCCOptionECBMode), keyBytes.baseAddress, keyBytes.count,
                      nil, &ref)
    }
    guard status == kCCSuccess, let ref else {
      throw OvozError(code: .decryption, message: "Could not create the AES cipher (status \(status))")
    }
    cryptor = ref
    let bytes = [UInt8](iv)
    ivHigh = bytes[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
    ivLow = bytes[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
  }

  deinit {
    // Releasing the cryptor zeroes its key schedule.
    CCCryptorRelease(cryptor)
    if !keystream.isEmpty { keystream.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
  }

  /// Decrypts (or encrypts: CTR is symmetric) [data] in place, where
  /// `data[0]` is byte [offset] of the plaintext.
  func apply(_ data: inout Data, at offset: Int64) {
    guard !data.isEmpty else { return }
    let firstBlock = UInt64(offset) / UInt64(Self.blockSize)
    let skip = Int(UInt64(offset) % UInt64(Self.blockSize))
    let blockCount = (skip + data.count + Self.blockSize - 1) / Self.blockSize
    let byteCount = blockCount * Self.blockSize

    if counters.count < byteCount {
      counters = [UInt8](repeating: 0, count: byteCount)
      keystream = [UInt8](repeating: 0, count: byteCount)
    }
    fillCounters(from: firstBlock, blocks: blockCount)

    var moved = 0
    let status = counters.withUnsafeBytes { input in
      keystream.withUnsafeMutableBytes { output in
        CCCryptorUpdate(cryptor, input.baseAddress, byteCount, output.baseAddress, byteCount, &moved)
      }
    }
    precondition(status == kCCSuccess && moved == byteCount, "AES-ECB keystream failed: \(status)")

    keystream.withUnsafeBytes { stream in
      data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
        let key = stream.baseAddress!.advanced(by: skip).assumingMemoryBound(to: UInt8.self)
        let bytes = out.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<out.count { bytes[i] ^= key[i] }
      }
    }
  }

  /// Counter blocks IV + first, IV + first + 1, … as 128-bit big-endian
  /// integers, carrying from the low half into the high half.
  private func fillCounters(from first: UInt64, blocks: Int) {
    counters.withUnsafeMutableBytes { raw in
      var (low, overflow) = ivLow.addingReportingOverflow(first)
      var high = overflow ? ivHigh &+ 1 : ivHigh
      for block in 0..<blocks {
        let base = block * Self.blockSize
        raw.storeBytes(of: high.bigEndian, toByteOffset: base, as: UInt64.self)
        raw.storeBytes(of: low.bigEndian, toByteOffset: base + 8, as: UInt64.self)
        (low, overflow) = low.addingReportingOverflow(1)
        if overflow { high = high &+ 1 }
      }
    }
  }
}
