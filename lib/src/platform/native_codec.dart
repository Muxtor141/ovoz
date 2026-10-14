import 'package:ovoz/src/audio_error.dart';
import 'package:ovoz/src/media_controls.dart';
import 'package:ovoz/src/player_state.dart';

/// What Dart and the native engines exchange as plain numbers: enum indices
/// and bit sets. The same on every platform, so the engine adapters share it.
abstract final class NativeCodec {
  /// A set of commands as bits, each at its [MediaCommand] index.
  static int commandBits(Set<MediaCommand> commands) {
    var bits = 0;
    for (final command in commands) {
      bits |= 1 << command.index;
    }
    return bits;
  }

  static ProcessingState processingState(int raw) =>
      raw >= 0 && raw < ProcessingState.values.length ? ProcessingState.values[raw] : ProcessingState.idle;

  static AudioError error(int code, String message) => AudioError(
    code >= 0 && code < AudioErrorKind.values.length ? AudioErrorKind.values[code] : AudioErrorKind.unknown,
    message,
  );

  /// [value] carries the position or interval in milliseconds, or the rate.
  static MediaCommandEvent commandEvent(int raw, double value) {
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
