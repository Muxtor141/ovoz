import AVFoundation
import Foundation

/// What went wrong, in categories an app can act on. The raw values are part
/// of the Dart contract (`AudioErrorKind`).
enum OvozErrorCode: Int {
  case unknown = 0
  case sourceNotFound = 1
  case network = 2
  case decryption = 3
  case unsupportedFormat = 4
  case rangeNotSupported = 5
  case invalidConfiguration = 6
}

struct OvozError: Error, CustomStringConvertible {
  static let domain = "uz.sayma.ovoz"

  let code: OvozErrorCode
  let message: String

  var description: String { "OvozError(\(code), \(message))" }

  var nsError: NSError {
    NSError(domain: Self.domain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
  }

  /// Classifies an AVFoundation, URL loading or file system error, walking the
  /// underlying-error chain: AVFoundation often wraps the cause it got from the
  /// network or from our resource loader.
  static func from(_ error: Error?) -> OvozError {
    guard let top = error as NSError? else {
      return OvozError(code: .unknown, message: "Playback failed for an unknown reason")
    }
    var next: NSError? = top
    var depth = 0
    while let e = next, depth < 8 {
      if let code = classify(e) {
        return OvozError(code: code, message: describe(top))
      }
      next = e.userInfo[NSUnderlyingErrorKey] as? NSError
      depth += 1
    }
    return OvozError(code: .unknown, message: describe(top))
  }

  private static func classify(_ e: NSError) -> OvozErrorCode? {
    switch e.domain {
    case domain:
      return OvozErrorCode(rawValue: e.code) ?? .unknown
    case NSURLErrorDomain:
      switch e.code {
      case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable: return .sourceNotFound
      case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return .invalidConfiguration
      default: return .network
      }
    case NSCocoaErrorDomain where e.code == NSFileNoSuchFileError || e.code == NSFileReadNoSuchFileError:
      return .sourceNotFound
    case "CoreMediaErrorDomain":
      // HTTP failures surface here: -12938 is a 404, -12660 a 403.
      switch e.code {
      case -12938, -12660, -12937: return .sourceNotFound
      default: return nil
      }
    case AVFoundationErrorDomain:
      switch AVError.Code(rawValue: e.code) {
      case .fileFormatNotRecognized, .decodeFailed, .failedToParse, .formatUnsupported, .noLongerPlayable:
        return .unsupportedFormat
      case .serverIncorrectlyConfigured:
        return .rangeNotSupported
      case .contentIsUnavailable, .fileFailedToParse:
        return .sourceNotFound
      default:
        return nil
      }
    default:
      return nil
    }
  }

  private static func describe(_ e: NSError) -> String {
    var parts = [e.localizedDescription]
    if let reason = e.localizedFailureReason { parts.append(reason) }
    if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
      parts.append("(\(underlying.domain) \(underlying.code): \(underlying.localizedDescription))")
    }
    return parts.joined(separator: " ")
  }
}
