import Foundation

/// Key material in memory the engine owns: copied in once, never logged, and
/// zeroed when released (ENC-06).
///
/// `Data` is copy-on-write, so zeroing a `Data` can miss copies that share its
/// storage; this keeps the only copy in a buffer of its own.
final class SecureBytes {
  private let buffer: UnsafeMutableRawBufferPointer

  init(_ data: Data) {
    buffer = .allocate(byteCount: data.count, alignment: 16)
    _ = data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
  }

  var count: Int { buffer.count }

  func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try body(UnsafeRawBufferPointer(buffer))
  }

  deinit {
    if let base = buffer.baseAddress {
      // memset_s is never optimised away, unlike a plain memset before free.
      memset_s(base, buffer.count, 0, buffer.count)
    }
    buffer.deallocate()
  }

  /// Never prints the bytes.
  var debugDescription: String { "SecureBytes(\(count) bytes)" }
}
