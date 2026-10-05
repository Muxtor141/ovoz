import 'package:flutter/foundation.dart';

/// Categories of failure an app can act on. Packages don't translate text, so
/// apps map these to their own messages.
enum AudioErrorKind {
  unknown,

  /// The file, asset or URL does not exist (or the server refused it).
  sourceNotFound,

  /// The network failed.
  network,

  /// The bytes did not decrypt to the declared format: wrong key or IV, or
  /// the wrong format declared.
  decryption,

  /// The platform cannot decode the audio.
  unsupportedFormat,

  /// An encrypted remote file's server does not answer byte-range requests
  /// (or compresses them), which decryption needs.
  rangeNotSupported,

  /// The request itself was invalid, for example an encrypted source without
  /// a format.
  invalidConfiguration,
}

/// Why an item could not be loaded or played.
@immutable
final class AudioError implements Exception {
  const AudioError(this.kind, this.message);

  final AudioErrorKind kind;

  /// A technical description for logs; not for users.
  final String message;

  @override
  String toString() => 'AudioError(${kind.name}): $message';
}

/// Thrown by a pending [AudioPlayer.setSource] or [AudioPlayer.setQueue] when
/// another load replaced it before it finished.
final class LoadInterruptedException implements Exception {
  const LoadInterruptedException();

  @override
  String toString() => 'LoadInterruptedException: a newer load replaced this one';
}

/// Thrown by [AudioSession.configure] and [AudioSession.setActive] when the
/// system refuses.
final class AudioSessionException implements Exception {
  const AudioSessionException(this.message);

  final String message;

  @override
  String toString() => 'AudioSessionException: $message';
}
