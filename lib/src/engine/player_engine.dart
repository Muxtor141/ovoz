import 'package:flutter/foundation.dart';

import 'package:ovoz/src/audio_error.dart';
import 'package:ovoz/src/audio_source.dart';
import 'package:ovoz/src/media_controls.dart';
import 'package:ovoz/src/player_state.dart';

/// The core engine contract for one player: everything that must happen
/// natively, nothing that can be decided once in Dart.
///
/// An engine plays the item it is given, keeps one cued item ready so it can
/// advance without a gap and without waiting for Dart, decrypts, buffers,
/// reports what happens, and owns the lock screen when asked. It knows no
/// queue, no order, no loop or shuffle, and no meaning of "previous": that is
/// [AudioPlayer]'s job, written once for every platform and unit-tested with
/// a fake engine.
///
/// Calls are synchronous and cheap (direct FFI calls on iOS); results arrive
/// as [events]. Continuously changing values ([position], [bufferedPosition])
/// are read, not pushed.
abstract interface class PlayerEngine {
  /// Engine events, in the order the engine produced them.
  Stream<EngineEvent> get events;

  /// Makes [item] current at [position] (within its clip), dropping any cued
  /// item. Keeps playing if playback is wanted. Null empties the engine.
  void setItem(EngineItem? item, Duration position);

  /// Cues [item] to follow the current one. Null cues nothing.
  void setNextItem(EngineItem? item);

  void play();
  void pause();

  /// Releases items and decoders; the engine becomes idle.
  void stop();

  void seek(Duration position);
  void setSpeed(double speed);
  void setVolume(double volume);
  void setPitchCorrection(PitchCorrection mode);

  /// Pause at the end of an item; a cued item becomes current, paused.
  set pauseAtItemEnd(bool value);

  void enableMediaControls(MediaControls controls);
  void disableMediaControls();

  /// "3 of 12" on the lock screen; [index] is zero-based.
  void setQueuePosition(int index, int count);

  Duration get position;
  Duration get bufferedPosition;
  Duration? get duration;

  /// The [EngineItem.id] of the current item; null when nothing is loaded.
  int? get currentItemId;

  ProcessingState get processingState;
  bool get playing;

  /// Whether the device has a network, as last reported; changes arrive as
  /// [EngineNetworkChanged].
  bool get networkAvailable;

  /// Releases the native player. The engine cannot be used again.
  void dispose();
}

/// A source as handed to an engine. [id] is new each time, even for the same
/// source, so events always say which instance they are about.
@immutable
final class EngineItem {
  const EngineItem(this.id, this.source);

  final int id;
  final AudioSource source;

  @override
  String toString() => 'EngineItem($id, $source)';
}

@immutable
sealed class EngineEvent {
  const EngineEvent();
}

final class EngineStateChanged extends EngineEvent {
  const EngineStateChanged(this.state, this.playing);

  final ProcessingState state;
  final bool playing;

  @override
  String toString() => 'EngineStateChanged(${state.name}, playing: $playing)';
}

/// Item [itemId] became current: set, or advanced into from the cue.
final class EngineItemStarted extends EngineEvent {
  const EngineItemStarted(this.itemId);

  final int itemId;

  @override
  String toString() => 'EngineItemStarted($itemId)';
}

/// Item [itemId] played to its end.
final class EngineItemEnded extends EngineEvent {
  const EngineItemEnded(this.itemId);

  final int itemId;

  @override
  String toString() => 'EngineItemEnded($itemId)';
}

final class EngineDurationChanged extends EngineEvent {
  const EngineDurationChanged(this.itemId, this.duration);

  final int itemId;
  final Duration duration;

  @override
  String toString() => 'EngineDurationChanged($itemId, $duration)';
}

/// Item [itemId] could not load, or stopped playing. For the current item it
/// comes before the state the failure causes (idle, playback no longer
/// wanted), so the player still knows whether playback was wanted.
final class EngineItemFailed extends EngineEvent {
  const EngineItemFailed(this.itemId, this.error);

  final int itemId;
  final AudioError error;

  @override
  String toString() => 'EngineItemFailed($itemId, $error)';
}

/// A media control command, for the engine that owns the controls.
final class EngineMediaCommand extends EngineEvent {
  const EngineMediaCommand(this.event);

  final MediaCommandEvent event;

  @override
  String toString() => 'EngineMediaCommand($event)';
}

/// The network came back, went away, or moved to another interface (Wi-Fi to
/// cellular).
final class EngineNetworkChanged extends EngineEvent {
  const EngineNetworkChanged({required this.available});

  /// Whether there is a network now.
  final bool available;

  @override
  String toString() => 'EngineNetworkChanged(available: $available)';
}
