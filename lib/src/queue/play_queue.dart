import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:ovoz/src/audio_source.dart';
import 'package:ovoz/src/player_state.dart';

/// One place in the queue. Compared by identity: the same source can appear
/// twice, and an entry keeps its identity while others move around it.
final class QueueEntry {
  QueueEntry(this.source);

  final AudioSource source;

  @override
  String toString() => 'QueueEntry($source)';
}

/// The queue's contents and its playing order: what comes after, and before,
/// a given entry under the loop and shuffle settings.
///
/// Pure Dart with no notion of playback, so every rule in it is unit-tested
/// directly. [AudioPlayer] asks it what to play; the engine only ever sees the
/// current item and the one cued after it.
final class PlayQueue {
  PlayQueue({Random? random}) : _random = random ?? Random();

  final Random _random;
  final List<QueueEntry> _entries = [];

  /// The shuffled order, while shuffling.
  List<QueueEntry>? _shuffled;

  LoopMode loopMode = LoopMode.off;

  List<QueueEntry> get entries => List.unmodifiable(_entries);

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;
  bool get shuffle => _shuffled != null;

  /// The order entries play in.
  List<QueueEntry> get order => _shuffled ?? _entries;

  /// [order] as indices into [entries].
  List<int> get orderIndices => [for (final entry in order) _entries.indexOf(entry)];

  QueueEntry? entryAt(int index) => index >= 0 && index < _entries.length ? _entries[index] : null;

  /// The entry's index, or null if it is no longer in the queue.
  int? indexOf(QueueEntry? entry) {
    if (entry == null) return null;
    final index = _entries.indexOf(entry);
    return index < 0 ? null : index;
  }

  /// What plays after [entry]. [automatic] means the entry ended by itself,
  /// where [LoopMode.one] repeats it; an explicit "next" moves on regardless.
  QueueEntry? after(QueueEntry entry, {required bool automatic}) {
    if (automatic && loopMode == LoopMode.one) return _entries.contains(entry) ? entry : null;
    final order = this.order;
    final position = order.indexOf(entry);
    if (position < 0) return null;
    if (position + 1 < order.length) return order[position + 1];
    return loopMode == LoopMode.all && order.isNotEmpty ? order.first : null;
  }

  /// What plays before [entry] on an explicit "previous".
  QueueEntry? before(QueueEntry entry) {
    final order = this.order;
    final position = order.indexOf(entry);
    if (position < 0) return null;
    if (position > 0) return order[position - 1];
    return loopMode == LoopMode.all && order.isNotEmpty ? order.last : null;
  }

  // ── Changes ──────────────────────────────────────────────────────────

  /// Replaces the contents. When shuffling, [first] (the entry about to play)
  /// leads the new order.
  List<QueueEntry> replaceAll(List<AudioSource> sources, {int? firstIndex}) {
    _entries
      ..clear()
      ..addAll(sources.map(QueueEntry.new));
    if (_shuffled != null) _reshuffle(entryAt(firstIndex ?? -1));
    return entries;
  }

  /// Inserts at [index]. While shuffling, the new entry goes to a random
  /// place after [current] in the order, so it still plays.
  QueueEntry insert(int index, AudioSource source, {QueueEntry? current}) {
    RangeError.checkValueInInterval(index, 0, _entries.length, 'index');
    final entry = QueueEntry(source);
    _entries.insert(index, entry);
    final shuffled = _shuffled;
    if (shuffled != null) {
      final after = current == null ? -1 : shuffled.indexOf(current);
      final low = after + 1;
      shuffled.insert(low + _random.nextInt(shuffled.length - low + 1), entry);
    }
    return entry;
  }

  QueueEntry removeAt(int index) {
    RangeError.checkValidIndex(index, _entries, 'index');
    final entry = _entries.removeAt(index);
    _shuffled?.remove(entry);
    return entry;
  }

  /// Moves an entry; the shuffled order is unaffected.
  void move(int from, int to) {
    RangeError.checkValidIndex(from, _entries, 'from');
    RangeError.checkValidIndex(to, _entries, 'to');
    final entry = _entries.removeAt(from);
    _entries.insert(to, entry);
  }

  /// Puts a new entry for [source] in place of the one at [index], keeping
  /// its place in the shuffled order.
  QueueEntry replace(int index, AudioSource source) {
    RangeError.checkValidIndex(index, _entries, 'index');
    final old = _entries[index];
    final entry = QueueEntry(source);
    _entries[index] = entry;
    final shuffled = _shuffled;
    if (shuffled != null) shuffled[shuffled.indexOf(old)] = entry;
    return entry;
  }

  void clear() {
    _entries.clear();
    _shuffled?.clear();
  }

  /// Turns shuffling on (with [current] first, so what plays now keeps
  /// playing and the rest follows in a new random order) or off.
  void setShuffle(bool enabled, {QueueEntry? current}) {
    if (!enabled) {
      _shuffled = null;
      return;
    }
    _reshuffle(current);
  }

  void _reshuffle(QueueEntry? first) {
    final rest = [..._entries]..remove(first);
    rest.shuffle(_random);
    _shuffled = [?first, ...rest];
  }

  @override
  String toString() =>
      'PlayQueue(${_entries.length} entries, ${loopMode.name}${shuffle ? ', shuffled' : ''})';
}

/// The queue as the UI sees it.
@immutable
final class QueueState {
  const QueueState({
    required this.sources,
    required this.currentIndex,
    required this.order,
    required this.loopMode,
    required this.shuffle,
  });

  static const QueueState empty = QueueState(
    sources: [],
    currentIndex: null,
    order: [],
    loopMode: LoopMode.off,
    shuffle: false,
  );

  final List<AudioSource> sources;
  final int? currentIndex;

  /// The playing order, as indices into [sources].
  final List<int> order;

  final LoopMode loopMode;
  final bool shuffle;

  @override
  bool operator ==(Object other) =>
      other is QueueState &&
      listEquals(other.sources, sources) &&
      other.currentIndex == currentIndex &&
      listEquals(other.order, order) &&
      other.loopMode == loopMode &&
      other.shuffle == shuffle;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(sources), currentIndex, Object.hashAll(order), loopMode, shuffle);
}
