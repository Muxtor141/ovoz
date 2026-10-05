import AVFoundation
import XCTest

@testable import OvozLoader

private func fixture(_ name: String) -> URL {
  Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
}

private func fixtureData(_ name: String) -> Data {
  try! Data(contentsOf: fixture(name))
}

// Demo key and IV (tool/make_test_vectors.sh), in Mutolaa's layout.
private let demoKey = Data("ovoz-demo-key-16".utf8)
private let demoIV = Data("ovoz-demo-iv--16".utf8)
private let key256 = Data((0..<32).map { UInt8($0) })

final class CipherTests: XCTestCase {
  func testDecryptsTheSeparateIVVector() throws {
    var data = fixtureData("sample_separate_iv.mp3.enc")
    try AesCtrCipher(key: SecureBytes(demoKey), iv: demoIV).apply(&data, at: 0)
    XCTAssertEqual(data, fixtureData("sample.mp3"))
  }

  func testRandomOffsetsMatchTheWholeFileDecrypt() throws {
    let cipherText = fixtureData("sample_separate_iv.mp3.enc")
    let plain = fixtureData("sample.mp3")
    let cipher = try AesCtrCipher(key: SecureBytes(demoKey), iv: demoIV)
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<500 {
      let start = Int.random(in: 0..<(cipherText.count - 1), using: &generator)
      let end = min(cipherText.count, start + Int.random(in: 1...70_000, using: &generator))
      var slice = cipherText.subdata(in: start..<end)
      cipher.apply(&slice, at: Int64(start))
      XCTAssertEqual(slice, plain.subdata(in: start..<end), "range \(start)..<\(end)")
    }
  }

  func testCounterCarriesAcrossAll128Bits() throws {
    var data = fixtureData("sample_carry.mp3.enc")
    try AesCtrCipher(key: SecureBytes(demoKey), iv: Data(repeating: 0xFF, count: 16)).apply(&data, at: 0)
    XCTAssertEqual(data, fixtureData("sample.mp3"))
  }

  func testAes256() throws {
    let file = fixtureData("sample_ivheader.mp3.enc")
    var body = file.subdata(in: 16..<file.count)
    try AesCtrCipher(key: SecureBytes(key256), iv: file.prefix(16)).apply(&body, at: 0)
    XCTAssertEqual(body, fixtureData("sample.mp3"))
  }

  func testRejectsBadKeyAndIVLengths() {
    XCTAssertThrowsError(try AesCtrCipher(key: SecureBytes(Data(count: 10)), iv: demoIV))
    XCTAssertThrowsError(try AesCtrCipher(key: SecureBytes(demoKey), iv: Data(count: 8)))
  }

  func testFormatSignatures() {
    let mp3 = AudioFormatInfo.named("mp3")!
    XCTAssertTrue(mp3.matches(fixtureData("sample.mp3")))
    XCTAssertFalse(mp3.matches(fixtureData("sample_separate_iv.mp3.enc")))
    XCTAssertTrue(AudioFormatInfo.named("m4a")!.matches(Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)))
    XCTAssertNil(AudioFormatInfo.named("ogg"))
  }
}

final class FileByteSourceTests: XCTestCase {
  private let queue = DispatchQueue(label: "test.loader")

  func testPrepareReportsLengthAndHeader() {
    let source = FileByteSource(path: fixture("sample.mp3").path, queue: queue)
    let done = expectation(description: "prepared")
    source.prepare(headerLength: 16) { result in
      let (length, header) = try! result.get()
      XCTAssertEqual(length, 170_147)
      XCTAssertEqual(header, fixtureData("sample.mp3").prefix(16))
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }

  func testReadDeliversTheRangeInOrder() {
    let source = FileByteSource(path: fixture("sample.mp3").path, queue: queue)
    var received = Data()
    let done = expectation(description: "read")
    _ = source.read(offset: 1000, count: 600_00, onData: { received.append($0); return true }) { error in
      XCTAssertNil(error)
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(received, fixtureData("sample.mp3").subdata(in: 1000..<61_000))
  }

  func testCancelStopsTheRead() {
    let source = FileByteSource(path: fixture("sample.mp3").path, queue: queue)
    var chunks = 0
    var read: ByteRead?
    let ended = expectation(description: "no end after cancel")
    ended.isInverted = true
    queue.sync {
      read = source.read(offset: 0, count: 170_147, onData: { _ in chunks += 1; read?.cancel(); return true }) { _ in
        ended.fulfill()
      }
    }
    wait(for: [ended], timeout: 0.5)
    XCTAssertEqual(chunks, 1)
  }

  func testMissingFile() {
    let source = FileByteSource(path: "/nonexistent/file.enc", queue: queue)
    let done = expectation(description: "failed")
    source.prepare(headerLength: 16) { result in
      if case .failure(let error) = result { XCTAssertEqual(error.code, .sourceNotFound) } else { XCTFail() }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }
}

final class HttpByteSourceTests: XCTestCase {
  private let queue = DispatchQueue(label: "test.http")

  private func source(_ behavior: RangeServer.Behavior) throws -> (HttpByteSource, RangeServer) {
    let server = try RangeServer(body: fixtureData("sample_separate_iv.mp3.enc"), behavior: behavior)
    let url = try server.start()
    addTeardownBlock { server.stop() }
    return (HttpByteSource(url: url, headers: ["Authorization": "Bearer t0ken"], queue: queue), server)
  }

  func testProbeAndRangeRead() throws {
    let (source, server) = try source(.honorRanges)
    let prepared = expectation(description: "prepared")
    source.prepare(headerLength: 28) { result in
      let (length, header) = try! result.get()
      XCTAssertEqual(length, 170_147)
      XCTAssertEqual(header, fixtureData("sample_separate_iv.mp3.enc").prefix(28))
      prepared.fulfill()
    }
    wait(for: [prepared], timeout: 5)

    var received = Data()
    let read = expectation(description: "read")
    _ = source.read(offset: 5000, count: 40_000, onData: { received.append($0); return true }) { error in
      XCTAssertNil(error)
      read.fulfill()
    }
    wait(for: [read], timeout: 5)
    XCTAssertEqual(received, fixtureData("sample_separate_iv.mp3.enc").subdata(in: 5000..<45_000))
    XCTAssertTrue(server.requests.allSatisfy { $0.contains("Authorization: Bearer t0ken") })
    source.close()
  }

  func testServerWithoutRangeSupportIsRejected() throws {
    let (source, _) = try source(.ignoreRanges)
    let done = expectation(description: "rejected")
    source.prepare(headerLength: 16) { result in
      if case .failure(let error) = result { XCTAssertEqual(error.code, .rangeNotSupported) } else { XCTFail() }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    source.close()
  }

  func testCompressedBodyIsRejected() throws {
    let (source, _) = try source(.compress)
    let done = expectation(description: "rejected")
    source.prepare(headerLength: 16) { result in
      if case .failure(let error) = result { XCTAssertEqual(error.code, .rangeNotSupported) } else { XCTFail() }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    source.close()
  }

  func testDroppedConnectionIsResumed() throws {
    let (source, server) = try source(.dropConnections(count: 2, afterBytes: 10_000))
    var received = Data()
    let done = expectation(description: "read")
    _ = source.read(offset: 0, count: 100_000, onData: { received.append($0); return true }) { error in
      XCTAssertNil(error)
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    XCTAssertEqual(received, fixtureData("sample_separate_iv.mp3.enc").prefix(100_000))
    XCTAssertEqual(server.requests.count, 3)
    source.close()
  }
}

final class DecryptingResourceLoaderTests: XCTestCase {
  private var loaders: [DecryptingResourceLoader] = []

  private func asset(_ source: (DispatchQueue) -> ByteSource, layout: EncryptionLayout,
                     onFailure: @escaping (OvozError) -> Void = { _ in }) -> AVURLAsset {
    let queue = DispatchQueue(label: "test.resource-loader")
    let format = AudioFormatInfo.named("mp3")!
    let loader = DecryptingResourceLoader(source: source(queue), layout: layout, format: format, queue: queue,
                                          onFailure: onFailure)
    loaders.append(loader) // AVFoundation holds its delegate weakly.
    let asset = AVURLAsset(url: DecryptingResourceLoader.url(itemId: 1, format: format))
    asset.resourceLoader.setDelegate(loader, queue: queue)
    return asset
  }

  private func localSource(_ name: String) -> (DispatchQueue) -> ByteSource {
    { FileByteSource(path: fixture(name).path, queue: $0) }
  }

  private func plainDuration() async throws -> Double {
    try await AVURLAsset(url: fixture("sample.mp3")).load(.duration).seconds
  }

  func testLoadsTheSeparateIVLayout() async throws {
    let asset = asset(localSource("sample_separate_iv.mp3.enc"),
                      layout: EncryptionLayout(key: SecureBytes(demoKey), iv: demoIV, dataOffset: 0))
    let duration = try await asset.load(.duration).seconds
    let expected = try await plainDuration()
    XCTAssertEqual(duration, expected, accuracy: 0.05)
    let playable = try await asset.load(.isPlayable)
    XCTAssertTrue(playable)
  }

  func testLoadsAnIVStoredInTheHeader() async throws {
    let asset = asset(localSource("sample_ivheader.mp3.enc"),
                      layout: EncryptionLayout(key: SecureBytes(key256), iv: nil, dataOffset: 16))
    let duration = try await asset.load(.duration).seconds
    let expected = try await plainDuration()
    XCTAssertEqual(duration, expected, accuracy: 0.05)
  }

  func testWrongKeyIsReportedAsADecryptionError() async throws {
    var reported: OvozError?
    let asset = asset(localSource("sample_separate_iv.mp3.enc"),
                      layout: EncryptionLayout(key: SecureBytes(Data(repeating: 7, count: 16)), iv: demoIV, dataOffset: 0),
                      onFailure: { reported = $0 })
    do {
      _ = try await asset.load(.duration)
      XCTFail("loaded with the wrong key")
    } catch {
      // AVFoundation reports an opaque "cannot open"; the precise cause comes
      // from the loader, which is why the player listens to it.
    }
    XCTAssertEqual(reported?.code, .decryption)
  }

  func testStreamsOverHttp() async throws {
    let server = try RangeServer(body: fixtureData("sample_separate_iv.mp3.enc"))
    let url = try server.start()
    defer { server.stop() }
    let asset = asset({ HttpByteSource(url: url, headers: [:], queue: $0) },
                      layout: EncryptionLayout(key: SecureBytes(demoKey), iv: demoIV, dataOffset: 0))
    let duration = try await asset.load(.duration).seconds
    let expected = try await plainDuration()
    XCTAssertEqual(duration, expected, accuracy: 0.05)
  }

  @MainActor
  func testPlaysToTheEndAfterASeek() async throws {
    let asset = asset(localSource("sample_separate_iv.mp3.enc"),
                      layout: EncryptionLayout(key: SecureBytes(demoKey), iv: demoIV, dataOffset: 0))
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.volume = 0
    let ended = expectation(forNotification: AVPlayerItem.didPlayToEndTimeNotification, object: item)

    let ready = expectation(description: "ready")
    let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
      if item.status == .readyToPlay { ready.fulfill() }
      if item.status == .failed { XCTFail("failed: \(String(describing: item.error))") }
    }
    await fulfillment(of: [ready], timeout: 5)
    observation.invalidate()

    player.play()
    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertGreaterThan(player.currentTime().seconds, 0.3, "playback did not advance")

    let seeked = await player.seek(to: CMTime(seconds: 10, preferredTimescale: 1000),
                                   toleranceBefore: .zero, toleranceAfter: .zero)
    XCTAssertTrue(seeked)
    XCTAssertEqual(player.currentTime().seconds, 10, accuracy: 0.1)
    await fulfillment(of: [ended], timeout: 5)
  }
}
