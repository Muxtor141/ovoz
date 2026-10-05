import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:ovoz/ovoz.dart';

/// The demo's audio: synthesized by `tool/make_example_media.py`, bundled as
/// assets, and copied to files where a real app would have downloaded them.
abstract final class DemoMedia {
  /// Mutolaa's layout (AES-128-CTR, IV passed separately, no header) with a
  /// demo key. A real app gets its keys from its backend, never from code.
  static final encryption = AesCtrEncryption(
    key: Uint8List.fromList(utf8.encode('ovoz-demo-key-16')),
    iv: Uint8List.fromList(utf8.encode('ovoz-demo-iv--16')),
  );

  static final cover = Uri.parse('asset:///assets/images/cover.png');

  /// The encrypted chapters, copied out of the bundle as if downloaded.
  static Future<List<AudioSource>> bookChapters() async => [
    for (var i = 1; i <= 3; i++)
      AudioSource.file(
        await _download('chapter_$i.m4a.enc'),
        encryption: encryption,
        format: AudioFormat.m4a,
        tag: i,
        metadata: MediaMetadata(
          title: 'Chapter $i',
          artist: 'Ovoz demo',
          album: 'The Synthesized Book',
          artUri: cover,
          duration: const Duration(seconds: 40),
        ),
      ),
  ];

  static List<AudioSource> songs() => [
    for (final (name, title) in [('song_a', 'Morning'), ('song_b', 'Noon'), ('song_c', 'Evening')])
      AudioSource.asset(
        'assets/audio/$name.m4a',
        tag: name,
        metadata: MediaMetadata(title: title, artist: 'Ovoz demo', artUri: cover),
      ),
    for (final part in [1, 2])
      AudioSource.asset(
        'assets/audio/gapless_$part.m4a',
        tag: 'gapless_$part',
        metadata: MediaMetadata(title: 'Gapless chord, part $part', artist: 'Ovoz demo', artUri: cover),
      ),
  ];

  static Future<String> _download(String asset) async {
    final file = File('${Directory.systemTemp.path}/downloads/$asset');
    if (!file.existsSync()) {
      final data = await rootBundle.load('assets/audio/$asset');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return file.path;
  }
}
