import 'package:flutter/foundation.dart';

/// Something to play. Cheap to create: nothing is opened until a player loads
/// it, and a queue of a thousand sources holds a thousand small descriptors.
@immutable
final class AudioSource {
  /// A local file.
  AudioSource.file(
    String path, {
    AesCtrEncryption? encryption,
    AudioFormat? format,
    ClipRange? clip,
    MediaMetadata? metadata,
    Object? tag,
  }) : this._(
         Uri.file(path),
         const {},
         encryption,
         format,
         clip,
         metadata,
         tag,
       );

  /// An asset bundled with the app, by the key used in `pubspec.yaml`
  /// (`assets/audio/click.wav`). Assets of another package need [package].
  AudioSource.asset(
    String key, {
    String? package,
    AesCtrEncryption? encryption,
    AudioFormat? format,
    ClipRange? clip,
    MediaMetadata? metadata,
    Object? tag,
  }) : this._(
         Uri(scheme: 'asset', path: '/${package == null ? key : 'packages/$package/$key'}'),
         const {},
         encryption,
         format,
         clip,
         metadata,
         tag,
       );

  /// A file or stream on the network: plain files, HLS (`.m3u8`), or an
  /// encrypted file (served with byte-range support).
  ///
  /// [headers] go with every request, including HLS segments and keys. No
  /// local proxy is involved.
  AudioSource.url(
    Uri url, {
    Map<String, String> headers = const {},
    AesCtrEncryption? encryption,
    AudioFormat? format,
    ClipRange? clip,
    MediaMetadata? metadata,
    Object? tag,
  }) : this._(
         url,
         Map.unmodifiable(headers),
         encryption,
         format,
         clip,
         metadata,
         tag,
       );

  AudioSource._(
    this.uri,
    this.headers,
    this.encryption,
    this.format,
    this.clip,
    this.metadata,
    this.tag,
  ) {
    if (encryption != null && format == null) {
      throw ArgumentError.value(
        format,
        'format',
        'An encrypted source must declare its format: the platform cannot '
            'detect the format of bytes it receives already decrypted',
      );
    }
  }

  /// `file:`, `asset:` or `http(s):`.
  final Uri uri;

  final Map<String, String> headers;

  /// Decrypt the bytes in memory as they are played. Never written to disk.
  final AesCtrEncryption? encryption;

  /// The container format. Required with [encryption]; otherwise detected.
  final AudioFormat? format;

  /// Play only part of the source.
  final ClipRange? clip;

  /// What the lock screen shows.
  final MediaMetadata? metadata;

  /// Anything the app wants to carry along: an id, a model. Read it back from
  /// [AudioPlayer.currentSource] to know what is playing.
  final Object? tag;

  /// This source with other [metadata], [clip] or [tag].
  AudioSource copyWith({MediaMetadata? metadata, ClipRange? clip, Object? tag}) => AudioSource._(
    uri,
    headers,
    encryption,
    format,
    clip ?? this.clip,
    metadata ?? this.metadata,
    tag ?? this.tag,
  );

  @override
  String toString() => 'AudioSource($uri${encryption != null ? ', encrypted' : ''})';
}

/// Container formats an encrypted source can declare. Plain sources need not
/// declare one.
enum AudioFormat { mp3, aac, m4a, wav, aiff, flac, caf }

/// AES in CTR mode, decrypted from any byte offset.
///
/// The IV is the first 16-byte counter block and counts as one 128-bit
/// big-endian integer, as PointyCastle (`encrypt`) and OpenSSL do.
@immutable
final class AesCtrEncryption {
  /// [key] is 16, 24 or 32 bytes; [iv] is 16 bytes. [dataOffset] is where the
  /// ciphertext starts, when the file has a header of the app's own.
  AesCtrEncryption({required Uint8List key, required Uint8List iv, this.dataOffset = 0})
    : key = Uint8List.fromList(key),
      iv = Uint8List.fromList(iv) {
    _checkKey(key);
    if (iv.length != 16) throw ArgumentError.value(iv.length, 'iv', 'The IV must be 16 bytes');
    if (dataOffset < 0) throw ArgumentError.value(dataOffset, 'dataOffset');
  }

  /// The IV is the file's first 16 bytes, and the ciphertext follows it (or
  /// starts at [dataOffset], if larger).
  AesCtrEncryption.ivInHeader({required Uint8List key, int dataOffset = 16})
    : key = Uint8List.fromList(key),
      iv = null,
      dataOffset = dataOffset < 16 ? 16 : dataOffset {
    _checkKey(key);
  }

  static void _checkKey(Uint8List key) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'An AES key is 16, 24 or 32 bytes');
    }
  }

  /// Handed to the platform once, when an item is created, and zeroed there
  /// when the item is released. The package never stores keys.
  final Uint8List key;

  /// Null when it is read from the file.
  final Uint8List? iv;

  final int dataOffset;

  /// Never prints the key.
  @override
  String toString() =>
      'AesCtrEncryption(${key.length * 8}-bit, ${iv == null ? 'IV in header' : 'IV given'}, offset $dataOffset)';
}

/// Part of a source: positions, the duration and the end of playback are
/// relative to [start].
@immutable
final class ClipRange {
  const ClipRange({this.start = Duration.zero, this.end});

  final Duration start;

  /// Null plays to the end of the source.
  final Duration? end;
}

/// What the lock screen, Control Center and cars show for a source.
@immutable
final class MediaMetadata {
  const MediaMetadata({
    required this.title,
    this.artist,
    this.album,
    this.artUri,
    this.duration,
  });

  final String title;
  final String? artist;
  final String? album;

  /// `https:`, `file:` or `asset:` image.
  final Uri? artUri;

  /// Shown until the player has measured the real length.
  final Duration? duration;
}
