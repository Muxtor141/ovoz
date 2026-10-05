import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:ovoz/src/audio_error.dart';
import 'package:ovoz/src/audio_source.dart';
import 'package:ovoz/src/engine/player_engine.dart';
import 'package:ovoz/src/media_controls.dart';
import 'package:ovoz/src/platform/engines.dart';
import 'package:ovoz/src/player_event.dart';
import 'package:ovoz/src/player_options.dart';
import 'package:ovoz/src/player_state.dart';
import 'package:ovoz/src/queue/play_queue.dart';
import 'package:ovoz/src/session/audio_session.dart';

/// Plays one source or a queue of them.
///
/// The player keeps the queue and decides what plays next (order, shuffle,
/// loop, what "previous" means), and turns the engine's raw facts into
/// streams an app can build on. The native engine underneath does the
/// playing: decoding, decryption, buffering, gapless transitions, the lock
/// screen. Create as many players as needed; they share one [AudioSession].
///
/// Commands return as soon as they are issued and never throw for playback
/// failures: those arrive on [events] as [ItemFailed] and leave the player
/// [ProcessingState.idle]. Only [setSource] and [setQueue] wait, for the item
/// to load, and throw if it cannot.
class AudioPlayer {
  AudioPlayer({PlayerOptions options = const PlayerOptions()})
    : this.withEngine(createPlayerEngine(), options: options);

  /// A player on [engine]: a fake one in tests, or another platform's.
  @visibleForTesting
  AudioPlayer.withEngine(PlayerEngine engine, {this.options = const PlayerOptions()})
    : _engine = engine,
      _pitchCorrection = options.pitchCorrection {
    _subscription = _engine.events.listen(_onEngineEvent);
    _engine.setPitchCorrection(options.pitchCorrection);
  }

  final PlayerOptions options;
  final PlayerEngine _engine;
  late final StreamSubscription<EngineEvent> _subscription;
  final _queue = PlayQueue();

  // ── What the engine holds ────────────────────────────────────────────

  int _nextInstanceId = 1;
  _Instance? _current;
  _Instance? _cued;

  /// Instance id → queue entry, for events about items that have since left
  /// the engine's window.
  final _recent = <int, QueueEntry>{};

  _PendingLoad? _pendingLoad;

  /// After [stop], or a failure, the engine holds nothing: [play] loads the
  /// current entry again at [_resumePosition].
  bool _stopped = false;
  bool _currentFailed = false;
  Duration _resumePosition = Duration.zero;

  /// Cued entries that failed to load, skipped over when cueing.
  final _unplayable = <QueueEntry>{};
  int _consecutiveErrors = 0;

  PitchCorrection _pitchCorrection;
  bool _pauseAtItemEnd = false;
  MediaControls? _mediaControls;
  bool _disposed = false;

  // ── Observable state ─────────────────────────────────────────────────

  final _state = _Value<PlayerState>(PlayerState.idle);
  final _duration = _Value<Duration?>(null);
  final _queueState = _Value<QueueState>(QueueState.empty);
  final _speed = _Value<double>(1);
  final _volume = _Value<double>(1);
  final _events = StreamController<PlayerEvent>.broadcast();
  late final _positions = _Poller<Duration>(() => position, options.positionInterval);
  late final _progress = _Poller<PlaybackProgress>(() => progress, options.positionInterval);

  PlayerState get playerState => _state.value;
  bool get playing => _state.value.playing;
  ProcessingState get processingState => _state.value.processingState;

  /// Read from the engine on every call (D-07).
  Duration get position {
    if (_current == null) return Duration.zero;
    if (_stopped || _currentFailed) return _resumePosition;
    return _engine.position;
  }

  Duration get bufferedPosition =>
      _current == null || _stopped || _currentFailed ? Duration.zero : _engine.bufferedPosition;

  /// The current item's length: the metadata's until the engine measures it.
  /// Null while unknown and for live streams.
  Duration? get duration => _duration.value;

  PlaybackProgress get progress =>
      PlaybackProgress(position: position, bufferedPosition: bufferedPosition, duration: duration);

  /// Index of the current item in [queue]; null when nothing is current.
  int? get currentIndex => _queueState.value.currentIndex;

  /// The current item. Its [AudioSource.tag] says what is playing.
  AudioSource? get currentSource => _current?.entry.source;

  List<AudioSource> get queue => _queueState.value.sources;
  QueueState get queueState => _queueState.value;
  LoopMode get loopMode => _queue.loopMode;
  bool get shuffle => _queue.shuffle;
  double get speed => _speed.value;
  double get volume => _volume.value;
  PitchCorrection get pitchCorrection => _pitchCorrection;
  MediaControls? get mediaControls => _mediaControls;

  /// Whether [skipToNext] has somewhere to go.
  bool get hasNext => _current != null && _queue.after(_current!.entry, automatic: false) != null;

  /// Whether [skipToPrevious] has an item to go back to (it can always
  /// restart the current one).
  bool get hasPrevious => _current != null && _queue.before(_current!.entry) != null;

  /// [playerState] now and on every change.
  Stream<PlayerState> get playerStateStream => _state.stream;
  Stream<bool> get playingStream => _state.stream.map((s) => s.playing).distinct();
  Stream<ProcessingState> get processingStateStream => _state.stream.map((s) => s.processingState).distinct();

  /// [currentIndex] now and on every change.
  Stream<int?> get currentIndexStream => _queueState.stream.map((q) => q.currentIndex).distinct();
  Stream<Duration?> get durationStream => _duration.stream;
  Stream<QueueState> get queueStream => _queueState.stream;
  Stream<double> get speedStream => _speed.stream;
  Stream<double> get volumeStream => _volume.stream;

  /// The position every [PlayerOptions.positionInterval] while listened to,
  /// and at once after seeks and item changes. Emits only changes.
  Stream<Duration> get positionStream => _positions.stream;

  /// Position, buffered position and duration together, for sliders.
  Stream<PlaybackProgress> get progressStream => _progress.stream;

  /// One-off events: an item played to its end ([ItemCompleted]), an item
  /// failed ([ItemFailed]).
  Stream<PlayerEvent> get events => _events.stream;

  // ── Loading ──────────────────────────────────────────────────────────

  /// Plays [source] alone. Completes with its duration once loaded (null for
  /// live streams); throws [AudioError] if it cannot load, or
  /// [LoadInterruptedException] if another load replaced it first.
  Future<Duration?> setSource(AudioSource source, {Duration initialPosition = Duration.zero}) =>
      setQueue([source], initialPosition: initialPosition);

  /// Replaces the queue and loads [sources] item [initialIndex] at
  /// [initialPosition]. Keeps playing if the player was playing. Completes as
  /// [setSource] does.
  Future<Duration?> setQueue(
    List<AudioSource> sources, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) {
    _checkNotDisposed();
    if (sources.isEmpty) {
      _clear();
      return Future.value();
    }
    RangeError.checkValidIndex(initialIndex, sources, 'initialIndex');
    _queue.replaceAll(sources, firstIndex: initialIndex);
    _unplayable.clear();
    _consecutiveErrors = 0;
    return _load(_queue.entryAt(initialIndex)!, initialPosition);
  }

  /// Empties the queue and the player.
  Future<void> clearQueue() async {
    _checkNotDisposed();
    _clear();
  }

  // ── Transport ────────────────────────────────────────────────────────

  /// Starts or resumes playback. Returns at once; it does not wait for
  /// playback to end. After [stop] or a failure, loads the item again first.
  Future<void> play() async {
    _checkNotDisposed();
    final current = _current;
    if (current != null && (_stopped || _currentFailed)) {
      _load(current.entry, _resumePosition).ignore();
    }
    _engine.play();
  }

  Future<void> pause() async {
    _checkNotDisposed();
    _engine.pause();
  }

  /// Stops and releases the decoders, keeping the queue, the current item
  /// and the position: [play] resumes from them.
  Future<void> stop() async {
    _checkNotDisposed();
    if (_current == null || _stopped) return;
    _resumePosition = position;
    _pendingLoad?.interrupt();
    _pendingLoad = null;
    _stopped = true;
    _cued = null;
    _engine.stop();
    _pollPositions();
  }

  /// Moves to [position] within the current item, or within item [index].
  Future<void> seek(Duration position, {int? index}) async {
    _checkNotDisposed();
    final target = position.isNegative ? Duration.zero : position;
    if (index != null) {
      final entry = _queue.entryAt(index);
      if (entry == null) throw RangeError.index(index, queue, 'index');
      if (entry != _current?.entry || _stopped || _currentFailed) {
        _consecutiveErrors = 0;
        _unplayable.remove(entry);
        _load(entry, target).ignore();
        return;
      }
    }
    if (_current == null) return;
    if (_stopped || _currentFailed) {
      _resumePosition = target;
      _pollPositions();
      return;
    }
    _engine.seek(target);
    _pollPositions();
  }

  /// Seeks by [offset] from the current position, staying within the item.
  Future<void> seekBy(Duration offset) {
    var target = position + offset;
    if (target.isNegative) target = Duration.zero;
    final duration = this.duration;
    if (duration != null && target > duration) target = duration;
    return seek(target);
  }

  /// Item [index] from its start: "jump to track".
  Future<void> skipToIndex(int index) => seek(Duration.zero, index: index);

  /// The next item in playing order (wrapping with [LoopMode.all]). Nothing
  /// at the end of the queue.
  Future<void> skipToNext() async {
    _checkNotDisposed();
    final current = _current;
    if (current == null) return;
    final next = _queue.after(current.entry, automatic: false);
    if (next == null) return;
    _consecutiveErrors = 0;
    _unplayable.remove(next);
    _load(next, Duration.zero).ignore();
  }

  /// Restarts the current item when more than
  /// [PlayerOptions.previousRestartThreshold] has played; otherwise goes to
  /// the previous item (or restarts the first).
  Future<void> skipToPrevious() async {
    _checkNotDisposed();
    final current = _current;
    if (current == null) return;
    final threshold = options.previousRestartThreshold;
    final previous = _queue.before(current.entry);
    if (previous == null || (threshold > Duration.zero && position > threshold)) {
      await seek(Duration.zero);
      return;
    }
    _consecutiveErrors = 0;
    _unplayable.remove(previous);
    _load(previous, Duration.zero).ignore();
  }

  Future<void> setSpeed(double speed) async {
    _checkNotDisposed();
    if (!speed.isFinite || speed <= 0) throw ArgumentError.value(speed, 'speed', 'Must be positive');
    _engine.setSpeed(speed);
    _speed.value = speed;
  }

  /// 0 to 1.
  Future<void> setVolume(double volume) async {
    _checkNotDisposed();
    final clamped = volume.clamp(0.0, 1.0);
    _engine.setVolume(clamped);
    _volume.value = clamped;
  }

  Future<void> setPitchCorrection(PitchCorrection mode) async {
    _checkNotDisposed();
    _pitchCorrection = mode;
    _engine.setPitchCorrection(mode);
  }

  Future<void> setLoopMode(LoopMode mode) async {
    _checkNotDisposed();
    _queue.loopMode = mode;
    _queueChanged();
  }

  /// Shuffles the playing order, keeping the current item current; off
  /// restores the queue's order.
  Future<void> setShuffle(bool enabled) async {
    _checkNotDisposed();
    if (enabled == _queue.shuffle) return;
    _queue.setShuffle(enabled, current: _current?.entry);
    _queueChanged();
  }

  /// When true, playback pauses at the end of each item instead of moving
  /// on; the next item becomes current, paused at its start. For a sleep
  /// timer's "stop after this chapter". [ItemCompleted] is still sent.
  bool get pauseAtItemEnd => _pauseAtItemEnd;

  set pauseAtItemEnd(bool value) {
    _checkNotDisposed();
    _pauseAtItemEnd = value;
    _engine.pauseAtItemEnd = value;
  }

  // ── Queue edits ──────────────────────────────────────────────────────

  Future<void> add(AudioSource source) => insert(_queue.length, source);

  Future<void> addAll(List<AudioSource> sources) async {
    _checkNotDisposed();
    for (final source in sources) {
      _queue.insert(_queue.length, source, current: _current?.entry);
    }
    _queueChanged();
  }

  Future<void> insert(int index, AudioSource source) async {
    _checkNotDisposed();
    _queue.insert(index, source, current: _current?.entry);
    _queueChanged();
  }

  /// Removes item [index]. Removing the current item moves to the one that
  /// takes its place, keeping the play state; the player goes idle if there
  /// is none.
  Future<void> removeAt(int index) async {
    _checkNotDisposed();
    final removed = _queue.removeAt(index);
    _unplayable.remove(removed);
    if (removed == _current?.entry) {
      final replacement = _queue.entryAt(index);
      if (replacement != null) {
        _load(replacement, Duration.zero).ignore(); // Publishes the queue.
        return;
      }
      _release();
    }
    _queueChanged();
  }

  Future<void> move(int from, int to) async {
    _checkNotDisposed();
    _queue.move(from, to);
    _queueChanged();
  }

  /// Puts [source] in place of item [index]. If it is the current item, the
  /// player switches to [source] at the same position, still playing if it
  /// was — for example from a stream to its finished download.
  Future<void> replaceAt(int index, AudioSource source, {bool keepPosition = true}) async {
    _checkNotDisposed();
    final old = _queue.entryAt(index);
    if (old == null) throw RangeError.index(index, queue, 'index');
    final entry = _queue.replace(index, source);
    _unplayable.remove(old);
    if (old == _current?.entry) {
      final at = keepPosition ? position : Duration.zero;
      if (_stopped) {
        _current = _instance(entry);
        _resumePosition = at;
      } else {
        _load(entry, at).ignore(); // Publishes the queue.
        return;
      }
    }
    _queueChanged();
  }

  // ── Media controls ───────────────────────────────────────────────────

  /// Puts this player on the lock screen, in Control Center and under
  /// headset and car controls, taking them from any other player; null takes
  /// it off. Commands go through this player's methods (play, skipToNext…),
  /// unless [MediaControls.onCommand] handles them.
  Future<void> setMediaControls(MediaControls? controls) async {
    _checkNotDisposed();
    _mediaControls = controls;
    if (controls == null) {
      _engine.disableMediaControls();
      return;
    }
    assert(_checkBackgroundSetup());
    _engine.enableMediaControls(controls);
    _queueChanged();
  }

  // ── Lifecycle ────────────────────────────────────────────────────────

  /// Stops playback and releases the native player. The player cannot be
  /// used again.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pendingLoad?.interrupt();
    await _subscription.cancel();
    _engine.dispose();
    _positions.close();
    _progress.close();
    for (final value in [_state, _duration, _queueState, _speed, _volume]) {
      value.close();
    }
    await _events.close();
  }

  // ── Internals ────────────────────────────────────────────────────────

  Future<Duration?> _load(QueueEntry entry, Duration position) {
    _pendingLoad?.interrupt();
    _stopped = false;
    _currentFailed = false;
    final instance = _instance(entry);
    _current = instance;
    _cued = null;
    _duration.value = entry.source.metadata?.duration;
    final pending = _pendingLoad = _PendingLoad(instance.id);
    _engine.setItem(EngineItem(instance.id, entry.source), position);
    _queueChanged();
    _pollPositions();
    return pending.future;
  }

  _Instance _instance(QueueEntry entry) {
    final id = _nextInstanceId++;
    _recent[id] = entry;
    if (_recent.length > 16) _recent.remove(_recent.keys.first);
    return _Instance(id, entry);
  }

  void _clear() {
    _queue.clear();
    _unplayable.clear();
    _release();
    _queueChanged();
  }

  /// Empties the engine: nothing is current.
  void _release() {
    _pendingLoad?.interrupt();
    _pendingLoad = null;
    _current = null;
    _cued = null;
    _stopped = false;
    _currentFailed = false;
    _duration.value = null;
    _engine.setItem(null, Duration.zero);
    _pollPositions();
  }

  /// Cues what should follow the current item, if that changed.
  void _syncCue() {
    final want = _wantedCue();
    if (identical(want, _cued?.entry)) return;
    if (want == null) {
      _cued = null;
      _engine.setNextItem(null);
      return;
    }
    final instance = _instance(want);
    _cued = instance;
    _engine.setNextItem(EngineItem(instance.id, want.source));
  }

  QueueEntry? _wantedCue() {
    final current = _current;
    if (current == null || _stopped || _currentFailed) return null;
    var want = _queue.after(current.entry, automatic: true);
    for (var skips = 0; want != null && _unplayable.contains(want); skips++) {
      if (skips >= options.maxSkipsOnError) return null;
      want = _queue.after(want, automatic: false);
    }
    return want;
  }

  void _queueChanged() {
    _syncCue();
    final current = _current?.entry;
    final index = _queue.indexOf(current);
    _queueState.value = QueueState(
      sources: [for (final entry in _queue.entries) entry.source],
      currentIndex: index,
      order: _queue.orderIndices,
      loopMode: _queue.loopMode,
      shuffle: _queue.shuffle,
    );
    if (index != null) _engine.setQueuePosition(_queue.order.indexOf(current!), _queue.length);
  }

  void _pollPositions() {
    _positions.poll();
    _progress.poll();
  }

  void _onEngineEvent(EngineEvent event) {
    if (_disposed) return;
    switch (event) {
      case EngineStateChanged(:final state, :final playing):
        _onState(state, playing);
      case EngineItemStarted(:final itemId):
        _onItemStarted(itemId);
      case EngineItemEnded(:final itemId):
        _onItemEnded(itemId);
      case EngineDurationChanged(:final itemId, :final duration):
        if (itemId == _current?.id) _duration.value = duration;
      case EngineItemFailed(:final itemId, :final error):
        _onItemFailed(itemId, error);
      case EngineMediaCommand(:final event):
        _onMediaCommand(event);
    }
  }

  void _onState(ProcessingState state, bool playing) {
    _state.value = PlayerState(playing, state);
    final pending = _pendingLoad;
    if (pending != null &&
        _engine.currentItemId == pending.id &&
        (state == ProcessingState.ready ||
            state == ProcessingState.buffering ||
            state == ProcessingState.completed)) {
      _pendingLoad = null;
      _consecutiveErrors = 0;
      pending.complete(_engine.duration);
    }
    _pollPositions();
  }

  /// The engine advanced into the cued item by itself.
  void _onItemStarted(int itemId) {
    final cued = _cued;
    if (cued == null || cued.id != itemId) return;
    _current = cued;
    _cued = null;
    _duration.value = cued.entry.source.metadata?.duration;
    _queueChanged();
    _pollPositions();
  }

  void _onItemEnded(int itemId) {
    final entry = _recent[itemId];
    if (entry == null) return;
    _events.add(
      ItemCompleted(
        index: _queue.indexOf(entry),
        source: entry.source,
        duration: itemId == _current?.id ? _duration.value : null,
      ),
    );
  }

  void _onItemFailed(int itemId, AudioError error) {
    final entry = _recent[itemId];
    if (entry == null) return;
    final pending = _pendingLoad;
    if (pending != null && pending.id == itemId) {
      _pendingLoad = null;
      pending.fail(error);
    }
    _events.add(ItemFailed(index: _queue.indexOf(entry), source: entry.source, error: error));

    if (itemId == _cued?.id) {
      // The engine dropped the cue: cue past it, or nothing, so the queue
      // stops at the end of the current item (PL-06).
      _unplayable.add(entry);
      _cued = null;
      _syncCue();
      return;
    }
    if (itemId != _current?.id) return;

    final wasPlaying = _state.value.playing;
    _resumePosition = _engine.position;
    _currentFailed = true;
    _cued = null;
    if (_consecutiveErrors < options.maxSkipsOnError) {
      final next = _queue.after(entry, automatic: false);
      if (next != null && next != entry) {
        _consecutiveErrors++;
        _load(next, Duration.zero).ignore();
        if (wasPlaying) _engine.play();
      }
    }
  }

  void _onMediaCommand(MediaCommandEvent event) {
    if (_mediaControls?.onCommand?.call(event) ?? false) return;
    final interval = event.interval ?? _mediaControls?.skipInterval ?? const Duration(seconds: 15);
    unawaited(switch (event.command) {
      MediaCommand.play => play(),
      MediaCommand.pause => pause(),
      MediaCommand.togglePlayPause => _state.value.showsPause ? pause() : play(),
      MediaCommand.stop => stop(),
      MediaCommand.next => skipToNext(),
      MediaCommand.previous => skipToPrevious(),
      MediaCommand.seek => seek(event.position ?? Duration.zero),
      MediaCommand.skipForward => seekBy(interval),
      MediaCommand.skipBackward => seekBy(-interval),
      MediaCommand.changeSpeed => setSpeed(event.speed ?? 1),
    });
  }

  /// SES-08 and BG-06, in debug builds: background playback needs the audio
  /// background mode and a session category that plays in the background.
  bool _checkBackgroundSetup() {
    try {
      final session = AudioSession.instance;
      if (!session.hasAudioBackgroundMode) {
        debugPrint(
          'ovoz: media controls are enabled but Info.plist lacks the "audio" '
          'UIBackgroundModes entry; playback will stop when the app goes to the background.',
        );
      }
      if (!session.config.supportsBackground) {
        debugPrint(
          'ovoz: media controls are enabled with a ${session.config.category.name} '
          'audio session, which does not play in the background.',
        );
      }
    } on UnsupportedError {
      // No platform session (tests with a fake engine).
    }
    return true;
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('This AudioPlayer was disposed');
  }
}

/// One hand-over of an entry to the engine.
final class _Instance {
  const _Instance(this.id, this.entry);

  final int id;
  final QueueEntry entry;
}

final class _PendingLoad {
  _PendingLoad(this.id);

  final int id;
  final _completer = Completer<Duration?>();

  Future<Duration?> get future => _completer.future;

  void complete(Duration? duration) {
    if (!_completer.isCompleted) _completer.complete(duration);
  }

  void fail(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }

  void interrupt() => fail(const LoadInterruptedException());
}

/// A value and its changes. Each listener first receives the current value.
final class _Value<T> {
  _Value(this._value);

  T _value;
  final _changes = StreamController<T>.broadcast();

  T get value => _value;

  set value(T next) {
    if (next == _value) return;
    _value = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  Stream<T> get stream => Stream<T>.multi((controller) {
    controller.add(_value);
    final subscription = _changes.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  void close() => unawaited(_changes.close());
}

/// A value read on a timer, only while someone listens. Each listener first
/// receives the latest value; afterwards only changes are emitted.
final class _Poller<T> {
  _Poller(this._read, this._interval);

  final T Function() _read;
  final Duration _interval;
  late final _controller = StreamController<T>.broadcast(onListen: _start, onCancel: _stop);
  Timer? _timer;
  T? _last;
  bool _hasLast = false;

  Stream<T> get stream => Stream<T>.multi((controller) {
    final first = !_controller.hasListener;
    final subscription = _controller.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    if (!first && _hasLast) controller.add(_last as T);
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  void _start() {
    _hasLast = false;
    poll();
    _timer = Timer.periodic(_interval, (_) => poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Reads now; emits if the value changed and someone listens.
  void poll() {
    if (_controller.isClosed || !_controller.hasListener) return;
    final value = _read();
    if (_hasLast && value == _last) return;
    _hasLast = true;
    _last = value;
    _controller.add(value);
  }

  void close() {
    _stop();
    unawaited(_controller.close());
  }
}
