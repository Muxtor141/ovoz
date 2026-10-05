import 'package:flutter/foundation.dart';

import 'package:ovoz/src/audio_error.dart';
import 'package:ovoz/src/audio_source.dart';

/// Something that happened once. See [AudioPlayer.events].
@immutable
sealed class PlayerEvent {
  const PlayerEvent({required this.index, required this.source});

  /// The item's index in the queue when the event happened; null if it was
  /// removed from the queue meanwhile.
  final int? index;

  final AudioSource source;
}

/// An item played to its end — not skipped, replaced or stopped. Sent once
/// per end, before the player moves on (or stops, at the end of the queue).
final class ItemCompleted extends PlayerEvent {
  const ItemCompleted({required super.index, required super.source, required this.duration});

  /// Its length as the player measured it; null if never known.
  final Duration? duration;

  @override
  String toString() => 'ItemCompleted($index, $source)';
}

/// An item could not be loaded or stopped playing because of [error].
final class ItemFailed extends PlayerEvent {
  const ItemFailed({required super.index, required super.source, required this.error});

  final AudioError error;

  @override
  String toString() => 'ItemFailed($index, $error)';
}
