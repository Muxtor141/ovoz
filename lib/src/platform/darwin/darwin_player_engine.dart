import 'dart:async';
import 'dart:typed_data';

// toNSString(), toNSData() and toDartString() conversions.
import 'package:objective_c/objective_c.dart';

import 'package:ovoz/src/audio_error.dart';
import 'package:ovoz/src/engine/player_engine.dart';
import 'package:ovoz/src/media_controls.dart';
import 'package:ovoz/src/platform/darwin/ovoz_bindings.g.dart';
import 'package:ovoz/src/player_state.dart';

/// [PlayerEngine] on the Swift engine (`OvozPlayer`), through ffigen
/// bindings: commands and reads are direct synchronous calls on the platform
/// thread, events come back through a listener the Swift side calls.
final class DarwinPlayerEngine implements PlayerEngine {
  DarwinPlayerEngine() {
    final listener = OvozPlayerListener$Builder.implementAsListener(
      onStateChanged_playing_: (state, playing) =>
          _emit(EngineStateChanged(ProcessingState.values[state], playing)),
      onItemStarted_: (id) => _emit(EngineItemStarted(id)),
      onItemEnded_: (id) => _emit(EngineItemEnded(id)),
      onDurationChanged_durationMs_: (id, ms) => _emit(EngineDurationChanged(id, Duration(milliseconds: ms))),
      onError_code_message_: (id, code, message) => _emit(
        EngineItemFailed(
          id,
          AudioError(
            code >= 0 && code < AudioErrorKind.values.length
                ? AudioErrorKind.values[code]
                : AudioErrorKind.unknown,
            message.toDartString(),
          ),
        ),
      ),
      onRemoteCommand_value_: (command, value) => _emit(EngineMediaCommand(_commandEvent(command, value))),
      $keepIsolateAlive: false,
    );
    _player = OvozPlayer.alloc().initWithListener(listener);
    _live.add(this);
  }

  /// Every engine not yet disposed (IO-03).
  ///
  /// A player must keep loading and playing even when the app holds no
  /// reference to it — a player created inside an async function, say, whose
  /// only reference is the frame waiting on the player's own load. The
  /// native player's callbacks cannot keep it alive (that reference runs
  /// through Objective-C, which Dart's garbage collector does not see), so
  /// engines are held here until [dispose], as other audio plugins do.
  static final _live = <DarwinPlayerEngine>{};

  late final OvozPlayer _player;
  final _events = StreamController<EngineEvent>.broadcast();

  @override
  Stream<EngineEvent> get events => _events.stream;

  /// Native events are posted to the isolate, so some can still arrive after
  /// [dispose].
  void _emit(EngineEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  void setItem(EngineItem? item, Duration position) =>
      _player.setItem(item == null ? null : _toNative(item), positionMs: position.inMilliseconds);

  @override
  void setNextItem(EngineItem? item) => _player.setNextItem(item == null ? null : _toNative(item));

  @override
  void play() => _player.play();

  @override
  void pause() => _player.pause();

  @override
  void stop() => _player.stop();

  @override
  void seek(Duration position) => _player.seekToMs(position.inMilliseconds);

  @override
  void setSpeed(double speed) => _player.setSpeed(speed);

  @override
  void setVolume(double volume) => _player.setVolume(volume);

  @override
  void setPitchCorrection(PitchCorrection mode) => _player.setPitchCorrection(mode.index);

  @override
  set pauseAtItemEnd(bool value) => _player.pauseAtItemEnd = value;

  @override
  void enableMediaControls(MediaControls controls) {
    var bits = 0;
    for (final command in controls.commands) {
      bits |= 1 << command.index;
    }
    final skip = controls.skipInterval.inMilliseconds;
    _player.enableMediaControls(bits, skipForwardMs: skip, skipBackwardMs: skip);
  }

  @override
  void disableMediaControls() => _player.disableMediaControls();

  @override
  void setQueuePosition(int index, int count) => _player.setQueuePosition(index, count: count);

  @override
  Duration get position => Duration(milliseconds: _player.positionMs);

  @override
  Duration get bufferedPosition => Duration(milliseconds: _player.bufferedPositionMs);

  @override
  Duration? get duration {
    final ms = _player.durationMs;
    return ms < 0 ? null : Duration(milliseconds: ms);
  }

  @override
  int? get currentItemId {
    final id = _player.currentItemId;
    return id < 0 ? null : id;
  }

  @override
  ProcessingState get processingState => ProcessingState.values[_player.processingState];

  @override
  bool get playing => _player.isPlaying;

  @override
  void dispose() {
    // Native dispose drops the listener, which releases its closures.
    _player.dispose();
    _live.remove(this);
    unawaited(_events.close());
  }

  static OvozItem _toNative(EngineItem item) {
    final source = item.source;
    final native = OvozItem.alloc().initWithItemId(item.id, uri: source.uri.toString().toNSString());
    source.headers.forEach((name, value) => native.addHeader(name.toNSString(), value: value.toNSString()));
    if (source.format case final format?) native.format = format.name.toNSString();
    if (source.encryption case final encryption?) {
      native.setAesCtrWithKey(
        encryption.key.toNSData(),
        iv: (encryption.iv ?? Uint8List(16)).toNSData(),
        ivInHeader: encryption.iv == null,
        dataOffset: encryption.dataOffset,
      );
    }
    if (source.clip case final clip?) {
      native.clipStartMs = clip.start.inMilliseconds;
      native.clipEndMs = clip.end?.inMilliseconds ?? -1;
    }
    if (source.metadata case final metadata?) {
      native.title = metadata.title.toNSString();
      if (metadata.artist case final artist?) native.artist = artist.toNSString();
      if (metadata.album case final album?) native.album = album.toNSString();
      if (metadata.artUri case final art?) native.artworkUri = art.toString().toNSString();
      if (metadata.duration case final duration?) native.durationHintMs = duration.inMilliseconds;
    }
    return native;
  }

  static MediaCommandEvent _commandEvent(int raw, double value) {
    final command = raw >= 0 && raw < MediaCommand.values.length
        ? MediaCommand.values[raw]
        : MediaCommand.togglePlayPause;
    final ms = Duration(milliseconds: value.round());
    return switch (command) {
      MediaCommand.seek => MediaCommandEvent(command, position: ms),
      MediaCommand.skipForward || MediaCommand.skipBackward => MediaCommandEvent(command, interval: ms),
      MediaCommand.changeSpeed => MediaCommandEvent(command, speed: value),
      _ => MediaCommandEvent(command),
    };
  }
}
