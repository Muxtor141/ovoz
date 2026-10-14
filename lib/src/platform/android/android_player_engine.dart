import 'dart:async';
import 'dart:typed_data';

import 'package:jni/jni.dart';

import 'package:ovoz/src/engine/player_engine.dart';
import 'package:ovoz/src/media_controls.dart';
import 'package:ovoz/src/platform/android/ovoz_bindings.g.dart';
import 'package:ovoz/src/platform/native_codec.dart';
import 'package:ovoz/src/player_state.dart';

/// [PlayerEngine] on the Kotlin engine (`OvozPlayer`, on Media3 ExoPlayer),
/// through jnigen bindings: commands and reads are direct synchronous calls on
/// the platform thread, events come back through a listener the Kotlin side
/// calls, posted to the isolate.
final class AndroidPlayerEngine implements PlayerEngine {
  AndroidPlayerEngine() {
    final listener = OvozPlayerListener.implement(
      $OvozPlayerListener(
        onStateChanged: (state, playing) =>
            _emit(EngineStateChanged(NativeCodec.processingState(state), playing)),
        onStateChanged$async: true,
        onItemStarted: (id) => _emit(EngineItemStarted(id)),
        onItemStarted$async: true,
        onItemEnded: (id) => _emit(EngineItemEnded(id)),
        onItemEnded$async: true,
        onDurationChanged: (id, ms) => _emit(EngineDurationChanged(id, Duration(milliseconds: ms))),
        onDurationChanged$async: true,
        onError: (id, code, message) =>
            _emit(EngineItemFailed(id, NativeCodec.error(code, message.toDartString(releaseOriginal: true)))),
        onError$async: true,
        onRemoteCommand: (command, value) =>
            _emit(EngineMediaCommand(NativeCodec.commandEvent(command, value))),
        onRemoteCommand$async: true,
        onNetworkChanged: (available) => _emit(EngineNetworkChanged(available: available)),
        onNetworkChanged$async: true,
      ),
    );
    _player = OvozPlayer(listener);
    // The native player holds the listener from here on.
    listener.release();
    _live.add(this);
  }

  /// Every engine not yet disposed (IO-03): a player keeps loading and
  /// playing even when the app holds no reference to it. The native player's
  /// callbacks cannot keep it alive (that reference runs through Java, which
  /// Dart's garbage collector does not see), so engines are held here until
  /// [dispose], as on iOS.
  static final _live = <AndroidPlayerEngine>{};

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
  void setItem(EngineItem? item, Duration position) {
    final native = item == null ? null : _toNative(item);
    _player.setItem(native, position.inMilliseconds);
    native?.release();
  }

  @override
  void setNextItem(EngineItem? item) {
    final native = item == null ? null : _toNative(item);
    _player.nextItem = native;
    native?.release();
  }

  @override
  void play() => _player.play();

  @override
  void pause() => _player.pause();

  @override
  void stop() => _player.stop();

  @override
  void seek(Duration position) => _player.seekTo(position.inMilliseconds);

  @override
  void setSpeed(double speed) => _player.speed = speed;

  @override
  void setVolume(double volume) => _player.volume = volume;

  @override
  void setPitchCorrection(PitchCorrection mode) => _player.pitchCorrection = mode.index;

  @override
  set pauseAtItemEnd(bool value) => _player.pauseAtItemEnd = value;

  @override
  void enableMediaControls(MediaControls controls) {
    final skip = controls.skipInterval.inMilliseconds;
    _player.enableMediaControls(NativeCodec.commandBits(controls.commands), skip, skip);
  }

  @override
  void disableMediaControls() => _player.disableMediaControls();

  @override
  void setQueuePosition(int index, int count) => _player.setQueuePosition(index, count);

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
  ProcessingState get processingState => NativeCodec.processingState(_player.processingState);

  @override
  bool get playing => _player.isPlaying;

  @override
  bool get networkAvailable => _player.isNetworkAvailable;

  @override
  void dispose() {
    // Native dispose drops the listener, which releases its closures.
    _player.dispose();
    _player.release();
    _live.remove(this);
    unawaited(_events.close());
  }

  static OvozItem _toNative(EngineItem item) => using((arena) {
    JString text(String value) => value.toJString()..releasedBy(arena);
    final source = item.source;
    final native = OvozItem(item.id, text(source.uri.toString()));
    source.headers.forEach((name, value) => native.addHeader(text(name), text(value)));
    if (source.format case final format?) native.format = text(format.name);
    if (source.encryption case final encryption?) {
      native.setAesCtr(
        _javaBytes(encryption.key)..releasedBy(arena),
        _javaBytes(encryption.iv ?? Uint8List(16))..releasedBy(arena),
        encryption.iv == null,
        encryption.dataOffset,
      );
    }
    if (source.clip case final clip?) {
      native.clipStartMs = clip.start.inMilliseconds;
      native.clipEndMs = clip.end?.inMilliseconds ?? -1;
    }
    if (source.metadata case final metadata?) {
      native.title = text(metadata.title);
      if (metadata.artist case final artist?) native.artist = text(artist);
      if (metadata.album case final album?) native.album = text(album);
      if (metadata.artUri case final art?) native.artworkUri = text(art.toString());
      if (metadata.duration case final duration?) native.durationHintMs = duration.inMilliseconds;
    }
    return native;
  });

  /// A Java copy of [bytes], written element by element so that no
  /// temporary native buffer holds key material on the way (ENC-06). The
  /// engine copies it and zeroes this array.
  static JByteArray _javaBytes(Uint8List bytes) {
    final array = JByteArray(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      array[i] = bytes[i];
    }
    return array;
  }
}
