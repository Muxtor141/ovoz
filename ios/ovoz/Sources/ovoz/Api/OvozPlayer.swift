import AVFoundation
import Foundation

/// Native events for one player, implemented in Dart (EVT-01).
///
/// Calls are asynchronous: they are posted to the Dart isolate and may come
/// from any thread. Values that change continuously (position, buffered
/// position) are not pushed; Dart reads them synchronously (EVT-03).
@objc(OvozPlayerListener)
public protocol OvozPlayerListener: NSObjectProtocol {
  /// [state] is an [OvozProcessingState]; [playing] is whether playback is
  /// wanted, which stays true while loading or buffering.
  func onStateChanged(_ state: Int, playing: Bool)

  /// Item [itemId] became current: loaded by `setItem`, or reached by
  /// advancing into the cued next item.
  func onItemStarted(_ itemId: Int64)

  /// Item [itemId] played to its end. Never sent for an item that was
  /// replaced, skipped or stopped.
  func onItemEnded(_ itemId: Int64)

  func onDurationChanged(_ itemId: Int64, durationMs: Int64)

  /// [code] is an [OvozErrorCode].
  func onError(_ itemId: Int64, code: Int, message: String)

  /// A lock-screen, headset or car command, for the player that owns the
  /// media controls. [command] is an [OvozRemoteCommand]; [value] carries the
  /// position or interval in milliseconds, or the rate.
  func onRemoteCommand(_ command: Int, value: Double)

  /// The network came back, went away, or moved to another interface (Wi-Fi
  /// to cellular): [available] is whether there is one now.
  func onNetworkChanged(_ available: Bool)
}

/// Processing states; the raw values are shared with Dart's `ProcessingState`.
@objc(OvozProcessingState)
public enum OvozProcessingState: Int {
  case idle = 0, loading, buffering, ready, completed
}

/// One playback stream (D-17: many may exist).
///
/// A mechanism, not a policy: it plays the item it is given, keeps the next
/// item Dart cued ready for a gapless transition, and reports what happens.
/// Which item comes next — order, shuffle, loop, what "previous" means — is
/// decided in Dart, once for every platform. The two-item window is all the
/// native side needs to advance without waiting for Dart (D-04).
///
/// Every method is called on the main thread: Dart runs there (merged
/// UI/platform threads, IO-01), and AVFoundation state is only touched there.
@objc(OvozPlayer)
public final class OvozPlayer: NSObject {
  private let player = AVQueuePlayer()
  private var listener: OvozPlayerListener?

  private var current: LoadedItem?
  private var next: LoadedItem?
  /// The item just advanced from, until its end notification has been seen.
  private var previous: LoadedItem?

  /// Whether playback is wanted (just_audio's "playing").
  private var playWhenReady = false
  /// The current item reached its end and nothing followed it.
  private var ended = false
  private var endReported: Int64?

  private var speed: Float = 1
  private var pitch: AVAudioTimePitchAlgorithm = .timeDomain
  private var seekGeneration = 0

  private var currentObservations: [NSKeyValueObservation] = []
  private var nextObservation: NSKeyValueObservation?
  private var playerObservations: [NSKeyValueObservation] = []
  private var lastState: (OvozProcessingState, Bool)?
  private var lastDuration: (Int64, Int64)?
  private var disposed = false

  @objc public init(listener: OvozPlayerListener) {
    self.listener = listener
    super.init()
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
    playerObservations = [
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
        onMain { self?.emitState() }
      },
      player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
        onMain { self?.currentItemChanged() }
      },
    ]
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(itemDidPlayToEnd(_:)),
                       name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
    center.addObserver(self, selector: #selector(itemFailedToPlayToEnd(_:)),
                       name: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil)
    OvozSessionManager.shared.register(self)
    OvozNetworkMonitor.shared.register(self)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: Items

  /// Makes [item] current, starting at [positionMs] within it (within its
  /// clip), and drops any cued item. Keeps playing if playback was wanted.
  /// Nil empties the player.
  @objc public func setItem(_ item: OvozItem?, positionMs: Int64) {
    assertMainThread()
    clearWindow()
    defer {
      updateActionAtItemEnd()
      emitState()
      updateNowPlaying()
    }
    guard let item else { return }

    switch LoadedItem.make(item, pitch: pitch, onLoaderFailure: loaderFailed) {
    case .failure(let error):
      // Nothing to show for it: report and stay idle.
      playWhenReady = false
      listener?.onError(item.itemId, code: error.code.rawValue, message: error.message)
    case .success(let loaded):
      current = loaded
      let start = loaded.absolute(CMTime(milliseconds: max(0, positionMs)))
      if start.seconds > 0 { loaded.pendingStart = start }
      observeCurrent(loaded)
      player.insert(loaded.playerItem, after: nil)
      listener?.onItemStarted(loaded.id)
      handleStatus(of: loaded)
      syncPlayback()
    }
  }

  /// Cues [item] to follow the current one without a gap; nil cues nothing,
  /// so the current item ends the stream (or pauses, see [pauseAtItemEnd]).
  @objc public func setNextItem(_ item: OvozItem?) {
    assertMainThread()
    dropNext()
    defer { updateActionAtItemEnd() }
    guard let item, let current, !current.failed else { return }

    switch LoadedItem.make(item, pitch: pitch, onLoaderFailure: loaderFailed) {
    case .failure(let error):
      listener?.onError(item.itemId, code: error.code.rawValue, message: error.message)
    case .success(let loaded):
      if loaded.clipStart.seconds > 0 { loaded.pendingStart = loaded.clipStart }
      guard player.canInsert(loaded.playerItem, after: current.playerItem) else { return }
      next = loaded
      player.insert(loaded.playerItem, after: current.playerItem)
      nextObservation = loaded.playerItem.observe(\.status, options: [.new]) { [weak self, weak loaded] _, _ in
        onMain {
          guard let self, let loaded, loaded === self.next, loaded.playerItem.status == .failed else { return }
          // A cued item that cannot load must not be advanced into; Dart hears
          // about it now and decides what to cue instead.
          self.dropNext()
          self.updateActionAtItemEnd()
          let error = loaded.loaderFailure ?? OvozError.from(loaded.playerItem.error)
          self.listener?.onError(loaded.id, code: error.code.rawValue, message: error.message)
        }
      }
    }
  }

  /// When true, the end of an item pauses playback instead of continuing; a
  /// cued item becomes current, paused at its start ("stop after this
  /// chapter").
  @objc public var pauseAtItemEnd = false {
    didSet { updateActionAtItemEnd() }
  }

  // MARK: Transport

  @objc public func play() {
    assertMainThread()
    if ended, let current {
      // Play after the end replays the item, as a play button would.
      ended = false
      current.pendingStart = current.clipStart
      handleStatus(of: current)
    }
    playWhenReady = true
    if current != nil { OvozSessionManager.shared.playerWillPlay() }
    syncPlayback()
    emitState()
    updateNowPlaying()
  }

  @objc public func pause() {
    assertMainThread()
    playWhenReady = false
    syncPlayback()
    emitState()
    updateNowPlaying()
  }

  /// Releases the items and their decoders. Dart keeps the queue and the
  /// position, and sets the item again to resume.
  @objc public func stop() {
    assertMainThread()
    playWhenReady = false
    clearWindow()
    updateActionAtItemEnd()
    emitState()
    updateNowPlaying()
  }

  @objc public func seek(toMs positionMs: Int64) {
    assertMainThread()
    guard let current, !current.failed else { return }
    let target = current.absolute(CMTime(milliseconds: max(0, positionMs)))
    ended = false
    if current.pendingStart != nil || current.playerItem.status != .readyToPlay {
      current.pendingStart = target
      handleStatus(of: current)
      emitState()
      return
    }
    seekGeneration += 1
    let generation = seekGeneration
    current.playerItem.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      onMain {
        guard let self, generation == self.seekGeneration else { return }
        self.syncPlayback()
        self.emitState()
        self.updateNowPlaying()
      }
    }
    syncPlayback()
    emitState()
    updateNowPlaying()
  }

  @objc public func setSpeed(_ value: Double) {
    assertMainThread()
    speed = Float(max(0.05, value))
    if #available(iOS 16.0, *) { player.defaultRate = speed }
    if player.rate != 0 { player.rate = speed }
    updateNowPlaying()
  }

  @objc public func setVolume(_ value: Double) {
    assertMainThread()
    player.volume = Float(min(1, max(0, value)))
  }

  /// 0: speech quality (time domain), 1: music quality (spectral), 2: no pitch
  /// correction (varispeed).
  @objc public func setPitchCorrection(_ mode: Int) {
    assertMainThread()
    pitch = switch mode {
    case 1: .spectral
    case 2: .varispeed
    default: .timeDomain
    }
    current?.playerItem.audioTimePitchAlgorithm = pitch
    next?.playerItem.audioTimePitchAlgorithm = pitch
  }

  // MARK: Synchronous state (D-07)

  @objc public var positionMs: Int64 {
    guard let current else { return 0 }
    if let pending = current.pendingStart { return current.relative(pending).milliseconds }
    if current.failed, let at = current.failedAt { return current.relative(at).milliseconds }
    if ended, let duration = current.duration { return duration.milliseconds }
    return current.relative(current.playerItem.currentTime()).milliseconds
  }

  @objc public var bufferedPositionMs: Int64 {
    guard let current else { return 0 }
    let now = current.playerItem.currentTime()
    var end = now
    for value in current.playerItem.loadedTimeRanges {
      let range = value.timeRangeValue
      // The range the playhead is in, allowing for a seek that landed just
      // before a range boundary.
      if range.start.seconds <= now.seconds + 0.5, range.end > end { end = range.end }
    }
    var relative = current.relative(end)
    if let duration = current.duration, relative > duration { relative = duration }
    return relative.milliseconds
  }

  /// -1 while unknown, and for live streams.
  @objc public var durationMs: Int64 { current?.duration?.milliseconds ?? -1 }

  /// -1 when nothing is loaded.
  @objc public var currentItemId: Int64 { current?.id ?? -1 }

  @objc public var processingState: Int { state.rawValue }

  @objc public var isPlaying: Bool { playWhenReady }

  /// Whether the device has a network, as last reported; true until the
  /// first report.
  @objc public var isNetworkAvailable: Bool { OvozNetworkMonitor.shared.isAvailable }

  // MARK: Media controls

  /// Makes this player the one the lock screen, Control Center, headsets and
  /// cars control (BG-02: at most one player at a time; this takes over from
  /// any other). [commands] is a bit set of [OvozRemoteCommand] raw values.
  @objc public func enableMediaControls(_ commands: Int, skipForwardMs: Int64, skipBackwardMs: Int64) {
    assertMainThread()
    NowPlayingCenter.shared.claim(self, commands: commands,
                                  skipForward: Double(skipForwardMs) / 1000, skipBackward: Double(skipBackwardMs) / 1000)
  }

  /// Takes this player off the lock screen (if it is there).
  @objc public func disableMediaControls() {
    assertMainThread()
    NowPlayingCenter.shared.release(self)
  }

  /// "3 of 12" on the lock screen.
  @objc public func setQueuePosition(_ index: Int, count: Int) {
    assertMainThread()
    queueIndex = index
    queueCount = count
    updateNowPlaying()
  }

  private(set) var queueIndex = -1
  private(set) var queueCount = 0

  func remoteCommand(_ command: OvozRemoteCommand, value: Double) {
    listener?.onRemoteCommand(command.rawValue, value: value)
  }

  // MARK: Lifecycle

  /// Stops playback and releases everything. The player cannot be used again.
  @objc public func dispose() {
    assertMainThread()
    guard !disposed else { return }
    disposed = true
    NowPlayingCenter.shared.release(self)
    playWhenReady = false
    clearWindow()
    playerObservations.forEach { $0.invalidate() }
    playerObservations = []
    NotificationCenter.default.removeObserver(self)
    OvozSessionManager.shared.unregister(self)
    OvozNetworkMonitor.shared.unregister(self)
    listener = nil
  }

  // MARK: Used by the network monitor

  func networkChanged(available: Bool) {
    guard !disposed else { return }
    listener?.onNetworkChanged(available)
  }

  // MARK: Used by the session manager

  /// The system paused audio for an interruption. Returns whether this player
  /// was playing, so it can be resumed when the interruption ends.
  func interruptionBegan() -> Bool {
    guard playWhenReady else { return false }
    playWhenReady = false
    syncPlayback()
    emitState()
    updateNowPlaying()
    return true
  }

  /// Plays on after the system paused AVFoundation for a route change the app
  /// chose to ignore.
  func resumeAfterRouteChange() {
    syncPlayback()
  }

  // MARK: Internals

  /// Metadata and timing the Now Playing center shows for this player.
  var nowPlayingSnapshot: NowPlayingSnapshot? {
    guard let current else { return nil }
    let duration = current.duration?.seconds
      ?? (current.descriptor.durationHintMs >= 0 ? Double(current.descriptor.durationHintMs) / 1000 : nil)
    return NowPlayingSnapshot(
      item: current.descriptor,
      isPlaying: playWhenReady && !ended && !current.failed,
      duration: duration,
      elapsed: Double(positionMs) / 1000,
      rate: state == .ready && playWhenReady ? Double(speed) : 0,
      defaultRate: Double(speed),
      queueIndex: queueIndex,
      queueCount: queueCount)
  }

  private var state: OvozProcessingState {
    guard let current else { return .idle }
    if current.failed { return .idle }
    if ended { return .completed }
    switch current.playerItem.status {
    case .unknown:
      return .loading
    case .failed:
      return .idle
    case .readyToPlay:
      if current.pendingStart != nil { return .loading }
      if playWhenReady, player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
         player.reasonForWaitingToPlay == .toMinimizeStalls {
        return .buffering
      }
      return .ready
    @unknown default:
      return .loading
    }
  }

  private func clearWindow() {
    seekGeneration += 1
    dropNext()
    if let current { detach(current) }
    current = nil
    previous = nil
    ended = false
    endReported = nil
    lastDuration = nil
    player.removeAllItems()
  }

  private func dropNext() {
    nextObservation?.invalidate()
    nextObservation = nil
    if let next, player.items().contains(where: { $0 === next.playerItem }) {
      player.remove(next.playerItem)
    }
    next = nil
  }

  private func updateActionAtItemEnd() {
    player.actionAtItemEnd = next != nil && !pauseAtItemEnd ? .advance : .pause
  }

  /// Puts AVFoundation's rate in line with what is wanted. Playback is held
  /// back while the item is still being positioned, so it never sounds from
  /// the wrong place.
  private func syncPlayback() {
    guard let current, !current.failed else {
      if player.rate != 0 { player.pause() }
      return
    }
    let shouldPlay = playWhenReady && !ended && current.pendingStart == nil
    if shouldPlay {
      if player.rate != speed { player.rate = speed }
    } else if player.rate != 0 {
      player.pause()
    }
  }

  private func observeCurrent(_ item: LoadedItem) {
    currentObservations = [
      item.playerItem.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
        onMain {
          guard let self, let item, item === self.current else { return }
          self.handleStatus(of: item)
          self.syncPlayback()
          self.emitState()
          self.updateNowPlaying()
        }
      },
      item.playerItem.observe(\.duration, options: [.new]) { [weak self, weak item] _, _ in
        onMain {
          guard let self, let item, item === self.current else { return }
          self.emitDuration()
          self.updateNowPlaying()
        }
      },
    ]
  }

  private func detach(_ item: LoadedItem) {
    currentObservations.forEach { $0.invalidate() }
    currentObservations = []
    if item.playerItem.status != .failed { item.playerItem.cancelPendingSeeks() }
  }

  /// Applies what an item's readiness allows: its pending start position, its
  /// duration, or its failure.
  private func handleStatus(of item: LoadedItem) {
    switch item.playerItem.status {
    case .readyToPlay:
      emitDuration()
      guard let start = item.pendingStart else { return }
      seekGeneration += 1
      let generation = seekGeneration
      item.playerItem.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] _ in
        onMain {
          guard let self, let item, item === self.current, generation == self.seekGeneration else { return }
          item.pendingStart = nil
          self.syncPlayback()
          self.emitState()
          self.updateNowPlaying()
        }
      }
    case .failed:
      fail(item, error: item.loaderFailure ?? OvozError.from(item.playerItem.error))
    default:
      break
    }
  }

  private func fail(_ item: LoadedItem, error: OvozError) {
    guard !item.failed else { return }
    // Captured before the pending start is dropped: a load that failed on its
    // way to minute 25 is resumed at minute 25.
    item.failedAt = item.pendingStart ?? item.playerItem.currentTime()
    item.failed = true
    item.pendingStart = nil
    // The error goes first. Stopping playback below makes the
    // timeControlStatus observer report the state there and then, and Dart
    // must hear of the failure while playback was still wanted.
    listener?.onError(item.id, code: error.code.rawValue, message: error.message)
    playWhenReady = false
    dropNext()
    updateActionAtItemEnd()
    syncPlayback()
    emitState()
    updateNowPlaying()
  }

  private func loaderFailed(_ itemId: Int64, _ error: OvozError) {
    onMain { [weak self] in
      guard let self else { return }
      for item in [self.current, self.next].compactMap({ $0 }) where item.id == itemId {
        item.loaderFailure = item.loaderFailure ?? error
      }
    }
  }

  private func currentItemChanged() {
    guard let current, let next, player.currentItem === next.playerItem else { return }
    // AVQueuePlayer moved into the cued item: the current one ended.
    reportEnd(of: current)
    detach(current)
    previous = current
    self.current = next
    self.next = nil
    nextObservation?.invalidate()
    nextObservation = nil
    ended = false
    observeCurrent(next)
    updateActionAtItemEnd()
    listener?.onItemStarted(next.id)
    handleStatus(of: next)
    syncPlayback()
    emitState()
    updateNowPlaying()
  }

  @objc private func itemDidPlayToEnd(_ notification: Notification) {
    guard let playerItem = notification.object as? AVPlayerItem else { return }
    onMain { [weak self] in
      guard let self else { return }
      if let previous = self.previous, previous.playerItem === playerItem {
        // Already advanced past it; the advance reported its end.
        self.reportEnd(of: previous)
        self.previous = nil
        return
      }
      guard let current = self.current, current.playerItem === playerItem else { return }
      self.reportEnd(of: current)
      if let next = self.next {
        if !self.pauseAtItemEnd { return } // AVQueuePlayer advances on its own.
        self.playWhenReady = false
        self.syncPlayback()
        self.player.advanceToNextItem()
        // The advance arrives through the currentItem observation, but run it
        // now so the reported state never shows the old item paused at its end.
        if self.player.currentItem === next.playerItem { self.currentItemChanged() }
        return
      }
      self.ended = true
      self.syncPlayback()
      self.emitState()
      self.updateNowPlaying()
    }
  }

  @objc private func itemFailedToPlayToEnd(_ notification: Notification) {
    guard let playerItem = notification.object as? AVPlayerItem else { return }
    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
    onMain { [weak self] in
      guard let self, let current = self.current, current.playerItem === playerItem else { return }
      self.fail(current, error: current.loaderFailure ?? OvozError.from(error))
    }
  }

  private func reportEnd(of item: LoadedItem) {
    guard endReported != item.id else { return }
    endReported = item.id
    listener?.onItemEnded(item.id)
  }

  private func emitState() {
    guard !disposed else { return }
    let snapshot = (state, playWhenReady)
    if let last = lastState, last == snapshot { return }
    lastState = snapshot
    listener?.onStateChanged(snapshot.0.rawValue, playing: snapshot.1)
    OvozSessionManager.shared.playerStateChanged()
  }

  private func emitDuration() {
    guard let current else { return }
    let ms = current.duration?.milliseconds ?? -1
    guard ms >= 0 else { return }
    if let last = lastDuration, last == (current.id, ms) { return }
    lastDuration = (current.id, ms)
    listener?.onDurationChanged(current.id, durationMs: ms)
  }

  private func updateNowPlaying() {
    NowPlayingCenter.shared.update(from: self)
  }
}

/// Runs [work] on the main thread: at once if already there, which keeps
/// event order intact for calls that start on the main thread.
func onMain(_ work: @escaping () -> Void) {
  if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
}

@inline(__always)
func assertMainThread(file: StaticString = #fileID, line: UInt = #line) {
  #if DEBUG
  if !Thread.isMainThread {
    assertionFailure("ovoz: call the engine from the main isolate on the platform thread (IO-01, IO-02)",
                     file: file, line: line)
  }
  #endif
}
