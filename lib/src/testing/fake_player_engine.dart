import 'dart:async';

import 'package:ovoz/src/audio_error.dart';
import 'package:ovoz/src/engine/player_engine.dart';
import 'package:ovoz/src/media_controls.dart';
import 'package:ovoz/src/player_state.dart';

/// A [PlayerEngine] that plays nothing and behaves like the native one: the
/// same events, in the same order. Tests drive time with [completeLoad],
/// [finishItem], [failCurrent] and friends.
///
/// Events are delivered asynchronously, as the native engine's are; let them
/// arrive (`await pumpEventQueue()`) before checking the player.
class FakePlayerEngine implements PlayerEngine {
  /// With [autoLoad], every item becomes ready at once, [defaultDuration]
  /// long; without it, call [completeLoad].
  FakePlayerEngine({this.autoLoad = true, this.defaultDuration = const Duration(minutes: 1)});

  final bool autoLoad;
  final Duration defaultDuration;

  /// Every command received, in order, for assertions.
  final List<String> log = [];

  EngineItem? currentItem;
  EngineItem? nextItem;

  @override
  Duration position = Duration.zero;

  @override
  Duration bufferedPosition = Duration.zero;

  Duration? _duration;
  bool _playing = false;
  ProcessingState _state = ProcessingState.idle;
  bool pauseAtEnd = false;
  double speed = 1;
  double volume = 1;
  PitchCorrection? pitchCorrection;
  MediaControls? mediaControls;
  (int index, int count)? queuePosition;
  bool disposed = false;

  final _events = StreamController<EngineEvent>.broadcast();

  @override
  Stream<EngineEvent> get events => _events.stream;

  // ── Driving it ───────────────────────────────────────────────────────

  /// The current item finished loading, [duration] long.
  void completeLoad([Duration? duration]) {
    final item = currentItem;
    if (item == null) throw StateError('Nothing is loading');
    _duration = duration ?? defaultDuration;
    _emit(EngineDurationChanged(item.id, _duration!));
    _setState(ProcessingState.ready);
  }

  /// The current item plays to its end: the engine advances into the cued
  /// item (paused, with [pauseAtItemEnd]), or completes.
  void finishItem() {
    final item = currentItem;
    if (item == null) throw StateError('Nothing is playing');
    position = _duration ?? position;
    _emit(EngineItemEnded(item.id));
    final next = nextItem;
    if (next == null) {
      _setState(ProcessingState.completed);
      return;
    }
    if (pauseAtEnd) _playing = false;
    currentItem = next;
    nextItem = null;
    position = Duration.zero;
    _duration = null;
    _emit(EngineItemStarted(next.id));
    if (autoLoad) {
      _duration = defaultDuration;
      _emit(EngineDurationChanged(next.id, defaultDuration));
    }
    _setState(ProcessingState.ready);
  }

  /// The current item fails; the engine stops wanting playback, like the
  /// native one.
  void failCurrent([AudioError error = const AudioError(AudioErrorKind.network, 'test failure')]) {
    final item = currentItem;
    if (item == null) throw StateError('Nothing is loaded');
    _playing = false;
    nextItem = null;
    _emit(EngineItemFailed(item.id, error));
    _setState(ProcessingState.idle);
  }

  /// The cued item fails to preload; the engine drops it.
  void failNext([AudioError error = const AudioError(AudioErrorKind.sourceNotFound, 'test failure')]) {
    final item = nextItem;
    if (item == null) throw StateError('Nothing is cued');
    nextItem = null;
    _emit(EngineItemFailed(item.id, error));
  }

  /// A lock-screen or headset command arrives.
  void sendCommand(MediaCommandEvent event) => _emit(EngineMediaCommand(event));

  // ── PlayerEngine ─────────────────────────────────────────────────────

  @override
  void setItem(EngineItem? item, Duration position) {
    log.add('setItem(${item?.id}, ${position.inMilliseconds})');
    currentItem = item;
    nextItem = null;
    this.position = position;
    _duration = null;
    if (item == null) {
      _setState(ProcessingState.idle);
      return;
    }
    _emit(EngineItemStarted(item.id));
    _setState(ProcessingState.loading);
    if (autoLoad) completeLoad();
  }

  @override
  void setNextItem(EngineItem? item) {
    log.add('setNextItem(${item?.id})');
    nextItem = item;
  }

  @override
  void play() {
    log.add('play');
    _playing = true;
    if (_state == ProcessingState.completed) {
      position = Duration.zero;
      _state = ProcessingState.ready;
    }
    _setState(_state);
  }

  @override
  void pause() {
    log.add('pause');
    _playing = false;
    _setState(_state);
  }

  @override
  void stop() {
    log.add('stop');
    _playing = false;
    currentItem = null;
    nextItem = null;
    _setState(ProcessingState.idle);
  }

  @override
  void seek(Duration position) {
    log.add('seek(${position.inMilliseconds})');
    this.position = position;
    if (_state == ProcessingState.completed) _setState(ProcessingState.ready);
  }

  @override
  void setSpeed(double speed) => this.speed = speed;

  @override
  void setVolume(double volume) => this.volume = volume;

  @override
  void setPitchCorrection(PitchCorrection mode) => pitchCorrection = mode;

  @override
  set pauseAtItemEnd(bool value) => pauseAtEnd = value;

  @override
  void enableMediaControls(MediaControls controls) => mediaControls = controls;

  @override
  void disableMediaControls() => mediaControls = null;

  @override
  void setQueuePosition(int index, int count) => queuePosition = (index, count);

  @override
  Duration? get duration => _duration;

  @override
  int? get currentItemId => currentItem?.id;

  @override
  ProcessingState get processingState => _state;

  @override
  bool get playing => _playing;

  @override
  void dispose() {
    log.add('dispose');
    disposed = true;
    unawaited(_events.close());
  }

  void _emit(EngineEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  (ProcessingState, bool)? _lastEmitted;

  /// Like the native engine, reports a state only when it changed.
  void _setState(ProcessingState state) {
    _state = state;
    final snapshot = (state, _playing);
    if (snapshot == _lastEmitted) return;
    _lastEmitted = snapshot;
    _emit(EngineStateChanged(state, _playing));
  }
}
