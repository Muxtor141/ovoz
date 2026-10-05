import Foundation

/// What the engine knows about a declared audio format.
///
/// AVFoundation cannot sniff a resource it loads through a custom URL scheme,
/// so encrypted sources declare their format and the loader reports its UTI
/// (ENC-05). The same table drives the wrong-key check (ENC-07): a correctly
/// decrypted file starts with its format's signature, a wrongly decrypted one
/// starts with noise.
struct AudioFormatInfo {
  let name: String
  let uti: String

  /// Plaintext bytes needed to check the signature.
  static let signatureLength = 12

  static func named(_ name: String) -> AudioFormatInfo? {
    switch name.lowercased() {
    case "mp3": return .init(name: "mp3", uti: "public.mp3")
    case "aac": return .init(name: "aac", uti: "public.aac-audio")
    case "m4a", "mp4", "m4b", "alac": return .init(name: "m4a", uti: "com.apple.m4a-audio")
    case "wav": return .init(name: "wav", uti: "com.microsoft.waveform-audio")
    case "aiff", "aif": return .init(name: "aiff", uti: "public.aiff-audio")
    case "flac": return .init(name: "flac", uti: "org.xiph.flac")
    case "caf": return .init(name: "caf", uti: "com.apple.coreaudio-format")
    default: return nil
    }
  }

  /// Whether [header] (the first plaintext bytes) can start a file of this
  /// format. Lenient where formats are: an MP3 may start with an ID3 tag or a
  /// bare frame, an MP4 with any top-level box.
  func matches(_ header: Data) -> Bool {
    let b = [UInt8](header.prefix(Self.signatureLength))
    guard b.count >= 4 else { return false }
    func ascii(_ s: String, at offset: Int) -> Bool {
      let expected = Array(s.utf8)
      guard b.count >= offset + expected.count else { return false }
      return Array(b[offset..<offset + expected.count]) == expected
    }
    switch name {
    case "mp3":
      return ascii("ID3", at: 0) || (b[0] == 0xFF && b[1] & 0xE0 == 0xE0)
    case "aac":
      return ascii("ID3", at: 0) || (b[0] == 0xFF && b[1] & 0xF6 == 0xF0)
    case "m4a":
      return ["ftyp", "moov", "mdat", "free", "skip", "wide", "pnot"].contains { ascii($0, at: 4) }
    case "wav":
      return ascii("RIFF", at: 0) || ascii("RF64", at: 0)
    case "aiff":
      return ascii("FORM", at: 0)
    case "flac":
      return ascii("fLaC", at: 0) || ascii("ID3", at: 0)
    case "caf":
      return ascii("caff", at: 0)
    default:
      return true
    }
  }
}
