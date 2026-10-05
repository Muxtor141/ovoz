import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovoz/ovoz.dart';
import 'package:ovoz/src/queue/play_queue.dart';

List<AudioSource> sources(int count) => [
  for (var i = 0; i < count; i++) AudioSource.file('/audio/$i.mp3', tag: i),
];

void main() {
  late PlayQueue queue;
  late List<QueueEntry> entries;

  setUp(() {
    queue = PlayQueue(random: Random(1));
    entries = queue.replaceAll(sources(4));
  });

  group('order without shuffle', () {
    test('next and previous follow the queue and stop at its ends', () {
      expect(queue.after(entries[0], automatic: false), entries[1]);
      expect(queue.after(entries[3], automatic: false), isNull);
      expect(queue.before(entries[1]), entries[0]);
      expect(queue.before(entries[0]), isNull);
    });

    test('loop all wraps both ways', () {
      queue.loopMode = LoopMode.all;
      expect(queue.after(entries[3], automatic: true), entries[0]);
      expect(queue.before(entries[0]), entries[3]);
    });

    test('loop one repeats on its own end but not on an explicit next', () {
      queue.loopMode = LoopMode.one;
      expect(queue.after(entries[2], automatic: true), entries[2]);
      expect(queue.after(entries[2], automatic: false), entries[3]);
    });
  });

  group('shuffle', () {
    test('keeps the current entry first and plays every entry once', () {
      queue.setShuffle(true, current: entries[2]);
      expect(queue.order.first, entries[2]);
      expect(queue.order.toSet(), entries.toSet());
      expect(queue.orderIndices.toSet(), {0, 1, 2, 3});
    });

    test('an inserted entry lands after the current one in the order', () {
      queue.setShuffle(true, current: entries[1]);
      for (var i = 0; i < 20; i++) {
        final entry = queue.insert(0, AudioSource.file('/audio/new$i.mp3'), current: entries[1]);
        expect(queue.order.indexOf(entry), greaterThan(queue.order.indexOf(entries[1])));
      }
    });

    test('removing an entry removes it from the order', () {
      queue.setShuffle(true, current: entries[0]);
      final removed = queue.removeAt(2);
      expect(queue.order, isNot(contains(removed)));
      expect(queue.order, hasLength(3));
    });

    test('turning it off restores the queue order', () {
      queue.setShuffle(true, current: entries[3]);
      queue.setShuffle(false);
      expect(queue.order, entries);
    });
  });

  test('replace keeps the place, also in the shuffled order', () {
    queue.setShuffle(true, current: entries[0]);
    final position = queue.order.indexOf(entries[2]);
    final replacement = queue.replace(2, AudioSource.file('/audio/download.mp3'));
    expect(queue.entries[2], replacement);
    expect(queue.order[position], replacement);
  });

  test('move changes the queue, not the identity of entries', () {
    queue.move(0, 3);
    expect(queue.entries, [entries[1], entries[2], entries[3], entries[0]]);
    expect(queue.indexOf(entries[0]), 3);
  });

  test('the same source twice is two entries', () {
    final source = AudioSource.file('/audio/a.mp3');
    final twice = queue.replaceAll([source, source]);
    expect(twice[0], isNot(same(twice[1])));
    expect(queue.after(twice[0], automatic: false), same(twice[1]));
  });
}
