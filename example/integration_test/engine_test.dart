// The real engine, end to end: Dart API -> FFI -> Swift -> AVFoundation.
//
//   cd example && flutter test integration_test -d <simulator id>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ovoz/ovoz.dart';
import 'package:ovoz_example/local_server.dart';

final mutolaaEncryption = AesCtrEncryption(
  key: Uint8List.fromList(utf8.encode('ovoz-demo-key-16')),
  iv: Uint8List.fromList(utf8.encode('ovoz-demo-iv--16')),
);

/// Copies a bundled asset to a file, as a download would be.
Future<String> fileFromAsset(String name) async {
  final data = await rootBundle.load('assets/audio/$name');
  final file = File('${Directory.systemTemp.path}/ovoz_test/$name');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return file.path;
}

/// Waits until [condition] holds, checking every 50 ms.
Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Matcher closeToDuration(Duration expected, Duration tolerance) => predicate<Duration?>(
  (d) => d != null && (d - expected).abs() <= tolerance,
  'within $tolerance of $expected',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AudioPlayer player;
  late List<PlayerEvent> events;

  setUpAll(() => AudioSession.instance.configure(const AudioSessionConfig.speech()));

  setUp(() {
    player = AudioPlayer(options: const PlayerOptions(positionInterval: Duration(milliseconds: 50)));
    events = [];
    player.events.listen(events.add);
    // Silent tests: the engine plays at full speed but inaudibly.
    unawaited(player.setVolume(0));
  });

  tearDown(() => player.dispose());

  testWidgets('plays an encrypted MP3 in Mutolaa\'s layout', (_) async {
    final path = await fileFromAsset('sample.mp3.enc');
    final duration = await player.setSource(
      AudioSource.file(path, encryption: mutolaaEncryption, format: AudioFormat.mp3),
    );
    expect(duration, closeToDuration(const Duration(milliseconds: 11729), const Duration(milliseconds: 100)));

    await player.play();
    await until(() => player.position > const Duration(milliseconds: 600));
    expect(player.playerState, const PlayerState(true, ProcessingState.ready));
  });

  testWidgets('seeks exactly inside an encrypted file', (_) async {
    final path = await fileFromAsset('chapter_1.m4a.enc');
    await player.setSource(AudioSource.file(path, encryption: mutolaaEncryption, format: AudioFormat.m4a));
    await player.seek(const Duration(seconds: 30));
    await until(() => player.processingState == ProcessingState.ready);
    expect(player.position, closeToDuration(const Duration(seconds: 30), const Duration(milliseconds: 100)));
    await player.play();
    await until(() => player.position > const Duration(milliseconds: 30500));
  });

  testWidgets('starts at an initial position in a queue item', (_) async {
    final path = await fileFromAsset('chapter_2.m4a.enc');
    await player.setQueue([
      AudioSource.file(path, encryption: mutolaaEncryption, format: AudioFormat.m4a),
    ], initialPosition: const Duration(seconds: 12));
    expect(player.position, closeToDuration(const Duration(seconds: 12), const Duration(milliseconds: 100)));
  });

  testWidgets('advances through a queue and reports each completion once', (_) async {
    await player.setQueue([
      AudioSource.asset('assets/audio/gapless_1.m4a', tag: 'one'),
      AudioSource.asset('assets/audio/gapless_2.m4a', tag: 'two'),
    ]);
    await player.seek(const Duration(milliseconds: 7300));
    await player.play();
    await until(() => player.currentIndex == 1);
    expect(player.currentSource!.tag, 'two');
    expect(events.whereType<ItemCompleted>().map((e) => e.index), [0]);
    expect(player.playing, isTrue);

    await player.seek(const Duration(milliseconds: 7500));
    await until(() => player.processingState == ProcessingState.completed);
    expect(events.whereType<ItemCompleted>().map((e) => e.index), [0, 1]);
  });

  testWidgets('pauses at an item end when asked, on the next item', (_) async {
    await player.setQueue([
      AudioSource.asset('assets/audio/song_a.m4a'),
      AudioSource.asset('assets/audio/song_b.m4a'),
    ]);
    player.pauseAtItemEnd = true;
    await player.seek(const Duration(milliseconds: 19300));
    await player.play();
    await until(() => player.currentIndex == 1);
    await until(() => !player.playing);
    expect(player.position, lessThan(const Duration(milliseconds: 200)));
    expect(events.whereType<ItemCompleted>(), hasLength(1));
  });

  testWidgets('loops one item', (_) async {
    await player.setSource(
      AudioSource.asset(
        'assets/audio/song_c.m4a',
        clip: const ClipRange(start: Duration(seconds: 2), end: Duration(seconds: 3)),
      ),
    );
    expect(player.duration, closeToDuration(const Duration(seconds: 1), const Duration(milliseconds: 50)));
    await player.setLoopMode(LoopMode.one);
    await player.play();
    await until(() => events.whereType<ItemCompleted>().length >= 2, timeout: const Duration(seconds: 6));
    expect(player.currentIndex, 0);
    expect(player.playing, isTrue);
  });

  testWidgets('skips next, previous and to an index', (_) async {
    await player.setQueue([
      for (final name in ['song_a', 'song_b', 'song_c'])
        AudioSource.asset('assets/audio/$name.m4a', tag: name),
    ]);
    await player.skipToNext();
    await until(() => player.processingState == ProcessingState.ready);
    expect(player.currentSource!.tag, 'song_b');
    await player.skipToIndex(2);
    await until(() => player.processingState == ProcessingState.ready);
    expect(player.currentSource!.tag, 'song_c');
    await player.skipToPrevious();
    await until(() => player.currentIndex == 1 && player.processingState == ProcessingState.ready);
  });

  testWidgets('stop releases, play resumes where it stopped', (_) async {
    await player.setSource(AudioSource.asset('assets/audio/song_a.m4a'));
    await player.seek(const Duration(seconds: 9));
    await until(() => player.position >= const Duration(seconds: 9));
    await player.stop();
    await until(() => player.processingState == ProcessingState.idle);
    await player.play();
    await until(() => player.playerState == const PlayerState(true, ProcessingState.ready));
    expect(player.position, closeToDuration(const Duration(seconds: 9), const Duration(milliseconds: 500)));
  });

  testWidgets('a wrong key is reported as a decryption error', (_) async {
    final path = await fileFromAsset('sample.mp3.enc');
    final wrongKey = AesCtrEncryption(key: Uint8List(16), iv: mutolaaEncryption.iv!);
    await expectLater(
      player.setSource(AudioSource.file(path, encryption: wrongKey, format: AudioFormat.mp3)),
      throwsA(isA<AudioError>().having((e) => e.kind, 'kind', AudioErrorKind.decryption)),
    );
    await until(() => events.isNotEmpty);
    expect(events.single, isA<ItemFailed>());
    expect(player.processingState, ProcessingState.idle);
  });

  testWidgets('a missing file is reported at once', (_) async {
    await expectLater(
      player.setSource(AudioSource.file('/nonexistent/chapter.mp3')),
      throwsA(isA<AudioError>().having((e) => e.kind, 'kind', AudioErrorKind.sourceNotFound)),
    );
  });

  testWidgets('players play at the same time', (_) async {
    final bed = AudioPlayer();
    addTearDown(bed.dispose);
    await bed.setVolume(0);
    await bed.setSource(AudioSource.asset('assets/audio/rain_loop.m4a'));
    await bed.setLoopMode(LoopMode.one);
    await player.setSource(AudioSource.asset('assets/audio/song_a.m4a'));
    await bed.play();
    await player.play();
    await until(
      () =>
          bed.position > const Duration(milliseconds: 500) &&
          player.position > const Duration(milliseconds: 500),
    );
    expect(bed.playing && player.playing, isTrue);
  });

  group('streaming, against a server inside the app', () {
    late LocalServer server;

    setUp(() async => server = await LocalServer.start());
    tearDown(() => server.close());

    testWidgets('an encrypted file over HTTP: byte ranges, bearer token, decrypted as it arrives', (_) async {
      final duration = await player.setSource(
        AudioSource.url(
          server.url('chapter_3.m4a.enc'),
          headers: const {'Authorization': 'Bearer ${LocalServer.token}'},
          encryption: mutolaaEncryption,
          format: AudioFormat.m4a,
        ),
      );
      expect(duration, closeToDuration(const Duration(seconds: 40), const Duration(milliseconds: 200)));
      await player.seek(const Duration(seconds: 25));
      await player.play();
      await until(() => player.position > const Duration(milliseconds: 25500));
      expect(server.requests, everyElement(contains('bytes=')));
    });

    testWidgets('a plain file with an auth header, without a proxy', (_) async {
      await player.setSource(
        AudioSource.url(
          server.url('song_b.m4a'),
          headers: const {'Authorization': 'Bearer ${LocalServer.token}'},
        ),
      );
      await player.play();
      await until(() => player.position > const Duration(milliseconds: 500));
    });

    testWidgets('a refused request is an error, not a hang', (_) async {
      await expectLater(
        player.setSource(AudioSource.url(server.url('song_c.m4a'))),
        throwsA(isA<AudioError>()),
      );
    });

    testWidgets('a refused encrypted request names the cause', (_) async {
      await expectLater(
        player.setSource(
          AudioSource.url(
            server.url('chapter_1.m4a.enc'),
            encryption: mutolaaEncryption,
            format: AudioFormat.m4a,
          ),
        ),
        throwsA(isA<AudioError>().having((e) => e.kind, 'kind', AudioErrorKind.sourceNotFound)),
      );
    });
  });
}
