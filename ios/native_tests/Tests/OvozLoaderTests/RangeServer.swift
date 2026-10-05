import Foundation
import Network

/// A tiny HTTP/1.1 server for one in-memory file, answering `Range` requests —
/// or misbehaving on purpose, to test how the engine copes with real servers.
final class RangeServer {
  enum Behavior {
    case honorRanges
    /// Answers every request with 200 and the whole body.
    case ignoreRanges
    /// Claims to gzip the body.
    case compress
    /// Closes the first [count] connections after [bytes] bytes of body.
    case dropConnections(count: Int, afterBytes: Int)
  }

  private let body: Data
  private let behavior: Behavior
  private let listener: NWListener
  private let queue = DispatchQueue(label: "RangeServer")
  private var dropsLeft = 0
  private(set) var requests: [String] = []

  init(body: Data, behavior: Behavior = .honorRanges) throws {
    self.body = body
    self.behavior = behavior
    if case .dropConnections(let count, _) = behavior { dropsLeft = count }
    listener = try NWListener(using: .tcp, on: .any)
  }

  /// Starts listening and returns the URL the file is served at.
  func start() throws -> URL {
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
      throw URLError(.cannotConnectToHost)
    }
    return URL(string: "http://127.0.0.1:\(port.rawValue)/audio.enc")!
  }

  func stop() { listener.cancel() }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
      guard let self, let data, let request = String(data: data, encoding: .utf8) else {
        connection.cancel()
        return
      }
      self.requests.append(request)
      self.respond(to: request, on: connection)
    }
  }

  private func respond(to request: String, on connection: NWConnection) {
    var start = 0
    var end = body.count - 1
    var ranged = false
    if let line = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }),
       let spec = line.split(separator: "=").last {
      let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
      start = Int(parts[0]) ?? 0
      if parts.count > 1, let last = Int(parts[1]) { end = min(last, body.count - 1) }
      ranged = true
    }

    var status = "206 Partial Content"
    var headers = ["Accept-Ranges: bytes"]
    switch behavior {
    case .ignoreRanges:
      status = "200 OK"
      start = 0
      end = body.count - 1
      ranged = false
    case .compress:
      headers.append("Content-Encoding: gzip")
    default:
      break
    }
    if ranged { headers.append("Content-Range: bytes \(start)-\(end)/\(body.count)") }
    let payload = body.subdata(in: start..<(end + 1))
    headers.append("Content-Length: \(payload.count)")
    headers.append("Connection: close")

    var response = Data("HTTP/1.1 \(status)\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
    if case .dropConnections(_, let afterBytes) = behavior, dropsLeft > 0 {
      dropsLeft -= 1
      response.append(payload.prefix(afterBytes))
      connection.send(content: response, completion: .contentProcessed { _ in connection.forceCancel() })
      return
    }
    response.append(payload)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }
}
