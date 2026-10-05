import Foundation

/// Where an encrypted resource's bytes come from: a local file or an HTTP
/// server that honours range requests.
///
/// Byte sources know nothing about AVFoundation or ciphers, so each one can be
/// tested on its own (P-06). Every callback runs on the queue passed to the
/// source's initializer: the resource loader's serial queue.
protocol ByteSource: AnyObject {
  /// Whether any byte range can be read at once, as from a local file. The
  /// player then reads only what it is about to play instead of buffering
  /// ahead in memory.
  var readsOnDemand: Bool { get }

  /// Learns the resource's total length and reads its first [headerLength]
  /// bytes (fewer if the resource is shorter). Called once, before any read.
  func prepare(headerLength: Int, completion: @escaping (Result<(length: Int64, header: Data), OvozError>) -> Void)

  /// Delivers bytes [offset, offset + count) in order, in pieces. [onData]
  /// returns false to stop early. [onEnd] runs exactly once, unless the read
  /// is cancelled first.
  func read(offset: Int64, count: Int64,
            onData: @escaping (Data) -> Bool,
            onEnd: @escaping (OvozError?) -> Void) -> ByteRead

  /// Releases files and connections. Pending reads end without callbacks.
  func close()
}

/// A read in progress.
protocol ByteRead: AnyObject {
  func cancel()
}

/// Reads a local file in chunks, yielding the queue between chunks so a
/// cancellation (a seek, the item going away) is handled promptly.
final class FileByteSource: ByteSource {
  static let chunkSize = 256 * 1024

  private let path: String
  private let queue: DispatchQueue
  private var handle: FileHandle?

  init(path: String, queue: DispatchQueue) {
    self.path = path
    self.queue = queue
  }

  var readsOnDemand: Bool { true }

  func prepare(headerLength: Int, completion: @escaping (Result<(length: Int64, header: Data), OvozError>) -> Void) {
    queue.async { [self] in
      do {
        let handle = try openHandle()
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: headerLength) ?? Data()
        completion(.success((Int64(length), header)))
      } catch let error as OvozError {
        completion(.failure(error))
      } catch {
        completion(.failure(OvozError(code: .sourceNotFound, message: "Cannot read \(path): \(error.localizedDescription)")))
      }
    }
  }

  func read(offset: Int64, count: Int64,
            onData: @escaping (Data) -> Bool,
            onEnd: @escaping (OvozError?) -> Void) -> ByteRead {
    let read = FileRead()
    var position = offset
    let end = offset + count

    func step() {
      guard !read.cancelled else { return }
      if position >= end {
        onEnd(nil)
        return
      }
      do {
        let handle = try openHandle()
        try handle.seek(toOffset: UInt64(position))
        let want = Int(min(Int64(Self.chunkSize), end - position))
        guard let data = try handle.read(upToCount: want), !data.isEmpty else {
          // The file is shorter than it was when prepared: deleted or truncated
          // while playing.
          onEnd(OvozError(code: .sourceNotFound, message: "\(path) ended early at byte \(position)"))
          return
        }
        position += Int64(data.count)
        guard onData(data) else { return }
        queue.async(execute: step)
      } catch {
        onEnd(OvozError(code: .sourceNotFound, message: "Cannot read \(path): \(error.localizedDescription)"))
      }
    }

    queue.async(execute: step)
    return read
  }

  func close() {
    queue.async { [self] in
      try? handle?.close()
      handle = nil
    }
  }

  private func openHandle() throws -> FileHandle {
    if let handle { return handle }
    guard let opened = FileHandle(forReadingAtPath: path) else {
      throw OvozError(code: .sourceNotFound, message: "No file at \(path)")
    }
    handle = opened
    return opened
  }

  private final class FileRead: ByteRead {
    var cancelled = false
    func cancel() { cancelled = true }
  }
}

/// Reads byte ranges over HTTP (`Range` requests), for encrypted files that
/// are streamed rather than downloaded.
///
/// The server must answer ranges with `206 Partial Content` and must not
/// compress the body; anything else is reported as `rangeNotSupported`, since
/// decryption needs exact byte offsets. Transient network errors are retried
/// twice with backoff before they surface.
final class HttpByteSource: NSObject, ByteSource, URLSessionDataDelegate {
  private let url: URL
  private let headers: [String: String]
  private let queue: DispatchQueue
  private lazy var session: URLSession = {
    let operations = OperationQueue()
    operations.underlyingQueue = queue
    operations.maxConcurrentOperationCount = 1
    let config = URLSessionConfiguration.default
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config, delegate: self, delegateQueue: operations)
  }()

  private var transfers: [Int: Transfer] = [:]

  init(url: URL, headers: [String: String], queue: DispatchQueue) {
    self.url = url
    self.headers = headers
    self.queue = queue
  }

  /// Every read costs a round trip: let the player buffer ahead, as it does for
  /// any progressive download.
  var readsOnDemand: Bool { false }

  func prepare(headerLength: Int, completion: @escaping (Result<(length: Int64, header: Data), OvozError>) -> Void) {
    var header = Data()
    var length: Int64?
    let transfer = Transfer(start: 0, end: Int64(max(headerLength, 1)) - 1)
    transfer.onLength = { length = $0 }
    transfer.onData = { data in header.append(data); return true }
    transfer.onEnd = { [url] error in
      if let error { completion(.failure(error)); return }
      guard let length else {
        completion(.failure(OvozError(code: .rangeNotSupported, message: "\(url) sent no Content-Range")))
        return
      }
      completion(.success((length, header)))
    }
    queue.async { self.start(transfer) }
  }

  func read(offset: Int64, count: Int64,
            onData: @escaping (Data) -> Bool,
            onEnd: @escaping (OvozError?) -> Void) -> ByteRead {
    let transfer = Transfer(start: offset, end: offset + count - 1)
    transfer.onData = onData
    transfer.onEnd = onEnd
    queue.async { self.start(transfer) }
    return transfer
  }

  func close() {
    queue.async { [self] in
      for transfer in transfers.values { transfer.cancel() }
      transfers.removeAll()
      session.invalidateAndCancel()
    }
  }

  // MARK: Transfers

  /// One range request, restarted from where it got to after a transient
  /// failure.
  private final class Transfer: ByteRead {
    let start: Int64
    let end: Int64
    var received: Int64 = 0
    var attempts = 0
    var cancelled = false
    var task: URLSessionDataTask?
    var onLength: ((Int64) -> Void)?
    var onData: ((Data) -> Bool)?
    var onEnd: ((OvozError?) -> Void)?

    init(start: Int64, end: Int64) {
      self.start = start
      self.end = end
    }

    func cancel() {
      cancelled = true
      task?.cancel()
    }
  }

  private static let maxRetries = 2

  private func start(_ transfer: Transfer) {
    guard !transfer.cancelled else { return }
    var request = URLRequest(url: url)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue("bytes=\(transfer.start + transfer.received)-\(transfer.end)", forHTTPHeaderField: "Range")
    // Decryption needs the exact bytes: no transparent compression.
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let task = session.dataTask(with: request)
    transfer.task = task
    transfers[task.taskIdentifier] = transfer
    task.resume()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let transfer = transfers[dataTask.taskIdentifier], !transfer.cancelled else {
      completionHandler(.cancel)
      return
    }
    let expectedStart = transfer.start + transfer.received
    let checked: Result<Int64, OvozError>
    if let http = response as? HTTPURLResponse {
      checked = Self.validate(http, start: expectedStart)
    } else {
      checked = .failure(OvozError(code: .network, message: "\(url) did not answer over HTTP"))
    }
    switch checked {
    case .success(let total):
      if transfer.received == 0 { transfer.onLength?(total) }
      completionHandler(.allow)
    case .failure(let error):
      transfers[dataTask.taskIdentifier] = nil
      transfer.onEnd?(error)
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let transfer = transfers[dataTask.taskIdentifier], !transfer.cancelled else { return }
    transfer.received += Int64(data.count)
    if transfer.onData?(data) == false {
      transfers[dataTask.taskIdentifier] = nil
      transfer.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let transfer = transfers.removeValue(forKey: task.taskIdentifier), !transfer.cancelled else { return }
    if let error = error as NSError? {
      if transfer.attempts < Self.maxRetries, Self.isTransient(error) {
        transfer.attempts += 1
        let delay = 0.5 * Double(transfer.attempts)
        queue.asyncAfter(deadline: .now() + delay) { self.start(transfer) }
        return
      }
      if error.domain == NSURLErrorDomain,
         [NSURLErrorCannotDecodeRawData, NSURLErrorCannotDecodeContentData].contains(error.code) {
        // URLSession failed to undo a compression the server applied anyway.
        transfer.onEnd?(OvozError(code: .rangeNotSupported,
                                  message: "\(url) compressed the body; byte offsets would not match"))
        return
      }
      transfer.onEnd?(OvozError.from(error))
      return
    }
    transfer.onEnd?(nil)
  }

  private static func isTransient(_ error: NSError) -> Bool {
    guard error.domain == NSURLErrorDomain else { return false }
    return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(error.code)
  }

  /// Total length from a `206` answer to a range starting at [start].
  private static func validate(_ response: HTTPURLResponse, start: Int64) -> Result<Int64, OvozError> {
    let url = response.url?.absoluteString ?? "server"
    switch response.statusCode {
    case 206:
      break
    case 200:
      return .failure(OvozError(code: .rangeNotSupported,
                                message: "\(url) ignored the Range header (200 instead of 206)"))
    case 401, 403, 404, 410:
      return .failure(OvozError(code: .sourceNotFound, message: "\(url) answered \(response.statusCode)"))
    default:
      return .failure(OvozError(code: .network, message: "\(url) answered \(response.statusCode)"))
    }
    if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
      return .failure(OvozError(code: .rangeNotSupported,
                                message: "\(url) compressed the body (\(encoding)); byte offsets would not match"))
    }
    // Content-Range: bytes 0-1023/146515
    guard let range = response.value(forHTTPHeaderField: "Content-Range"),
          let slash = range.lastIndex(of: "/"),
          let total = Int64(range[range.index(after: slash)...]) else {
      return .failure(OvozError(code: .rangeNotSupported, message: "\(url) sent no usable Content-Range"))
    }
    let first = range.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
    guard Int64(first) == start else {
      return .failure(OvozError(code: .rangeNotSupported, message: "\(url) answered a different range: \(range)"))
    }
    return .success(total)
  }
}
