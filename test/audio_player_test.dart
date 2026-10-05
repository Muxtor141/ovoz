import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovoz/ovoz.dart';
import 'package:ovoz/testing.dart';

List<AudioSource> chapters(int count) => [
  for (var i = 0; i < count; i++)
    AudioSource.file(
      '/books/1/$i.mp3',
      tag: 'chapter $i',
      metadata: MediaMetadata(title: 'Chapter $i'),
    ),
];

void main() {
  late FakePlayerEngine engine;
  late AudioPlayer player;
  late List<PlayerEvent> events;

  void build({PlayerOptions options = const PlayerOptions(), bool autoLoad = true}) {
    engine = FakePlayerEngine(autoLoad: autoLoad);
    player = AudioPlayer.withEngine(engine, options: options);
    events = [];
    player.events.listen(events.add);
  }

  setUp(build);
  tearDown(() => player.dispose());

  group('loading', () {
    test('setQueue loads the start item at its position and cues the next one', () async {
      final duration = await player.setQueue(
        chapters(3),
        initialIndex: 1,
        initialPosition: const Duration(seconds: 42),
      );
      await pumpEventQueue();

      expect(duration, engine.defaultDuration);
      expect(engine.log.first, 'setItem(1, 42000)');
      expect(engine.currentItem!.source.tag, 'chapter 1');
      expect(engine.nextItem!.source.tag, 'chapter 2');
      expect(player.currentIndex, 1);
      expect(player.currentSource!.tag, 'chapter 1');
      expect(player.processingState, ProcessingState.ready);
      expect(player.duration, engine.defaultDuration);
    });

    test('a newer load interrupts a pending one', () async {
      build(autoLoad: false);
      final first = player.setSource(chapters(1).single);
      final second = player.setSource(AudioSource.file('/other.mp3'));
      await expectLater(first, throwsA(isA<LoadInterruptedException>()));
      engine.completeLoad(const Duration(seconds: 30));
      expect(await second, const Duration(seconds: 30));
    });

    test('a failed load throws, reports, and play retries it where it was', () async {
      build(autoLoad: false);
      final load = player.setSource(chapters(1).single, initialPosition: const Duration(seconds: 5));
      engine.position = const Duration(seconds: 5);
      engine.failCurrent(const AudioError(AudioErrorKind.decryption, 'wrong key'));
      await expectLater(
        load,
        throwsA(isA<AudioError>().having((e) => e.kind, 'kind', AudioErrorKind.decryption)),
      );
      await pumpEventQueue();

      expect(events.single, isA<ItemFailed>().having((e) => e.index, 'index', 0));
      expect(player.processingState, ProcessingState.idle);
      expect(player.position, const Duration(seconds: 5));

      engine.log.clear();
      await player.play();
      // Nothing to cue after a single item: setItem already dropped the cue.
      expect(engine.log, ['setItem(2, 5000)', 'play']);
    });

    test('an encrypted source must declare its format', () {
      expect(
        () => AudioSource.file('/a.enc', encryption: AesCtrEncryption.ivInHeader(key: Uint8List(16))),
        throwsArgumentError,
      );
    });
  });

  group('advancing', () {
    test('an item end reports completion and the engine moves into the cue', () async {
      await player.setQueue(chapters(3));
      await player.play();
      engine.finishItem();
      await pumpEventQueue();

      expect(events.single, isA<ItemCompleted>().having((e) => e.index, 'index', 0));
      expect(player.currentIndex, 1);
      expect(engine.nextItem!.source.tag, 'chapter 2', reason: 'the following item is cued at once');
      expect(player.playing, isTrue);
    });

    test('the end of the queue completes', () async {
      await player.setQueue(chapters(2), initialIndex: 1);
      await player.play();
      expect(engine.nextItem, isNull);
      engine.finishItem();
      await pumpEventQueue();

      expect(events.single, isA<ItemCompleted>().having((e) => e.index, 'index', 1));
      expect(player.processingState, ProcessingState.completed);
      expect(player.playerState.showsPause, isFalse);
    });

    test('loop one cues a new instance of the same item, lap after lap', () async {
      await player.setQueue(chapters(2));
      await player.setLoopMode(LoopMode.one);
      final firstCue = engine.nextItem!;
      expect(firstCue.source.tag, 'chapter 0');
      expect(firstCue.id, isNot(engine.currentItem!.id));

      engine.finishItem();
      await pumpEventQueue();
      expect(player.currentIndex, 0);
      expect(engine.nextItem!.id, isNot(firstCue.id));
      engine.finishItem();
      await pumpEventQueue();
      expect(events.whereType<ItemCompleted>(), hasLength(2));
    });

    test('loop all cues the first item after the last', () async {
      await player.setQueue(chapters(3), initialIndex: 2);
      await player.setLoopMode(LoopMode.all);
      expect(engine.nextItem!.source.tag, 'chapter 0');
    });

    test('pauseAtItemEnd: the next item becomes current, paused', () async {
      await player.setQueue(chapters(3));
      await player.play();
      player.pauseAtItemEnd = true;
      engine.finishItem();
      await pumpEventQueue();

      expect(events.single, isA<ItemCompleted>());
      expect(player.currentIndex, 1);
      expect(player.playing, isFalse);
    });
  });

  group('navigation', () {
    test('skipToNext and skipToIndex load from the start, keeping play state', () async {
      await player.setQueue(chapters(4));
      await player.play();
      engine.log.clear();
      await player.skipToNext();
      await player.skipToIndex(3);
      await pumpEventQueue();

      expect(engine.log.where((l) => l.startsWith('setItem')), ['setItem(3, 0)', 'setItem(5, 0)']);
      expect(player.currentIndex, 3);
      expect(engine.playing, isTrue);
      expect(player.hasNext, isFalse);
    });

    test('skipToPrevious restarts after the threshold and goes back before it', () async {
      await player.setQueue(chapters(3), initialIndex: 1);
      engine.position = const Duration(seconds: 10);
      await player.skipToPrevious();
      expect(engine.log.last, 'seek(0)');
      expect(player.currentIndex, 1);

      engine.position = const Duration(seconds: 2);
      await player.skipToPrevious();
      await pumpEventQueue();
      expect(player.currentIndex, 0);
    });

    test('a zero threshold always goes back', () async {
      build(options: const PlayerOptions(previousRestartThreshold: Duration.zero));
      await player.setQueue(chapters(3), initialIndex: 2);
      engine.position = const Duration(minutes: 5);
      await player.skipToPrevious();
      await pumpEventQueue();
      expect(player.currentIndex, 1);
    });

    test('seekBy stays within the item', () async {
      await player.setQueue(chapters(1));
      engine.position = const Duration(seconds: 5);
      await player.seekBy(const Duration(seconds: -10));
      expect(engine.log.last, 'seek(0)');
      engine.position = const Duration(seconds: 55);
      await player.seekBy(const Duration(seconds: 10));
      expect(engine.log.last, 'seek(60000)');
    });

    test('shuffle keeps the current item and cues from the shuffled order', () async {
      await player.setQueue(chapters(6), initialIndex: 2);
      await player.setShuffle(true);
      final order = player.queueState.order;
      expect(order.first, 2);
      expect(engine.nextItem!.source.tag, 'chapter ${order[1]}');
    });
  });

  group('stop and resume', () {
    test('stop releases the engine; play loads the item again where it was', () async {
      await player.setQueue(chapters(2));
      await player.play();
      engine.position = const Duration(seconds: 20);
      await player.stop();
      await pumpEventQueue();
      expect(player.processingState, ProcessingState.idle);
      expect(player.position, const Duration(seconds: 20));

      engine.log.clear();
      await player.play();
      expect(engine.log, ['setItem(3, 20000)', 'setNextItem(4)', 'play']);
    });
  });

  group('queue edits', () {
    test('replacing the current item switches source at the same position', () async {
      await player.setQueue(chapters(3), initialIndex: 1);
      await player.play();
      engine.position = const Duration(seconds: 33);
      engine.log.clear();
      await player.replaceAt(1, AudioSource.file('/downloads/1.enc', tag: 'download'));
      expect(engine.log.first, 'setItem(3, 33000)');
      expect(player.currentSource!.tag, 'download');
      expect(player.currentIndex, 1);
    });

    test('inserting before the current item shifts its index, not the playback', () async {
      await player.setQueue(chapters(2), initialIndex: 1);
      engine.log.clear();
      await player.insert(0, AudioSource.file('/intro.mp3'));
      expect(player.currentIndex, 2);
      expect(engine.log.where((l) => l.startsWith('setItem')), isEmpty);
    });

    test('removing the current item moves to the one taking its place', () async {
      await player.setQueue(chapters(3), initialIndex: 1);
      await player.removeAt(1);
      await pumpEventQueue();
      expect(player.currentSource!.tag, 'chapter 2');
      expect(player.currentIndex, 1);
    });

    test('adding after the last item cues it', () async {
      await player.setQueue(chapters(1));
      expect(engine.nextItem, isNull);
      await player.add(AudioSource.file('/more.mp3', tag: 'more'));
      expect(engine.nextItem!.source.tag, 'more');
    });
  });

  group('errors', () {
    test('skips a failing item when allowed, and keeps playing', () async {
      build(options: const PlayerOptions(maxSkipsOnError: 1));
      await player.setQueue(chapters(3));
      await player.play();
      await pumpEventQueue();
      engine.failCurrent();
      await pumpEventQueue();

      expect(events.single, isA<ItemFailed>());
      expect(player.currentIndex, 1);
      expect(engine.playing, isTrue);
    });

    test('a cued item that fails is skipped over only when allowed', () async {
      await player.setQueue(chapters(3));
      engine.failNext();
      await pumpEventQueue();
      expect(engine.nextItem, isNull, reason: 'stop at the end of the current item');

      build(options: const PlayerOptions(maxSkipsOnError: 1));
      await player.setQueue(chapters(3));
      engine.failNext();
      await pumpEventQueue();
      expect(engine.nextItem!.source.tag, 'chapter 2');
    });
  });

  group('media controls', () {
    test('commands drive the player unless the app handles them', () async {
      await player.setQueue(chapters(3));
      final handled = <MediaCommand>[];
      await player.setMediaControls(
        MediaControls(
          onCommand: (event) {
            handled.add(event.command);
            return event.command == MediaCommand.next;
          },
        ),
      );
      expect(engine.mediaControls, isNotNull);
      expect(engine.queuePosition, (0, 3));

      engine.sendCommand(const MediaCommandEvent(MediaCommand.togglePlayPause));
      engine.sendCommand(const MediaCommandEvent(MediaCommand.next));
      engine.sendCommand(const MediaCommandEvent(MediaCommand.seek, position: Duration(seconds: 7)));
      engine.sendCommand(const MediaCommandEvent(MediaCommand.skipBackward, interval: Duration(seconds: 15)));
      await pumpEventQueue();

      expect(handled, [
        MediaCommand.togglePlayPause,
        MediaCommand.next,
        MediaCommand.seek,
        MediaCommand.skipBackward,
      ]);
      expect(engine.playing, isTrue);
      expect(player.currentIndex, 0, reason: 'the app handled "next"');
      expect(engine.log.where((l) => l.startsWith('seek')), ['seek(7000)', 'seek(0)']);

      await player.setMediaControls(null);
      expect(engine.mediaControls, isNull);
    });
  });

  group('streams', () {
    test('state streams give new listeners the current value', () async {
      await player.setQueue(chapters(3), initialIndex: 2);
      await pumpEventQueue();
      expect(await player.currentIndexStream.first, 2);
      expect(await player.playerStateStream.first, const PlayerState(false, ProcessingState.ready));
      expect((await player.queueStream.first).sources, hasLength(3));
    });

    test('positions are read only while listened to', () async {
      build(options: const PlayerOptions(positionInterval: Duration(milliseconds: 10)));
      await player.setQueue(chapters(1));
      engine.position = const Duration(seconds: 1);
      final positions = <Duration>[];
      final subscription = player.positionStream.listen(positions.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      engine.position = const Duration(seconds: 2);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await subscription.cancel();
      engine.position = const Duration(seconds: 3);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(positions, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });
  });

  test('dispose releases the engine and refuses further use', () async {
    await player.dispose();
    expect(engine.disposed, isTrue);
    expect(player.play, throwsStateError);
  });
}
