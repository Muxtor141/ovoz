import 'package:flutter/foundation.dart';

/// Where a player is in loading and playing its current item. Independent of
/// [PlayerState.playing]: a player can be playing and buffering at once.
///
/// The same model as just_audio, to ease migrating from it.
enum ProcessingState {
  /// Nothing loaded, stopped, or the current item failed.
  idle,

  /// The current item is being opened (or positioned).
  loading,

  /// Waiting for data in the middle of playback.
  buffering,

  /// Able to play.
  ready,

  /// The last item played to its end and nothing followed it.
  completed,
}

/// Whether playback is wanted, and where the player is in delivering it.
@immutable
final class PlayerState {
  const PlayerState(this.playing, this.processingState);

  static const PlayerState idle = PlayerState(false, ProcessingState.idle);

  /// Whether playback is wanted: true from [AudioPlayer.play] until a pause,
  /// stop or interruption, including while loading or buffering, and still at
  /// [ProcessingState.completed].
  final bool playing;

  final ProcessingState processingState;

  /// Loading or buffering while playback is wanted: the moment for a spinner.
  bool get isBusy =>
      playing && (processingState == ProcessingState.loading || processingState == ProcessingState.buffering);

  /// Whether a play/pause control should offer "pause".
  bool get showsPause => playing && processingState != ProcessingState.completed;

  @override
  bool operator ==(Object other) =>
      other is PlayerState && other.playing == playing && other.processingState == processingState;

  @override
  int get hashCode => Object.hash(playing, processingState);

  @override
  String toString() => 'PlayerState(${playing ? 'playing' : 'paused'}, ${processingState.name})';
}

/// What happens when the queue reaches an item's end.
enum LoopMode {
  /// Continue to the next item; stop after the last one.
  off,

  /// Repeat the current item.
  one,

  /// Continue to the next item; after the last one, start again from the
  /// first.
  all,
}

/// How speed changes treat pitch.
enum PitchCorrection {
  /// Keeps pitch; tuned for voice. The right choice for audiobooks.
  speech,

  /// Keeps pitch; tuned for music. Costs more CPU.
  music,

  /// Pitch follows speed, like a tape.
  none,
}

/// Position, buffered position and duration, read together for a slider.
@immutable
final class PlaybackProgress {
  const PlaybackProgress({
    required this.position,
    required this.bufferedPosition,
    required this.duration,
  });

  static const PlaybackProgress zero = PlaybackProgress(
    position: Duration.zero,
    bufferedPosition: Duration.zero,
    duration: null,
  );

  final Duration position;
  final Duration bufferedPosition;

  /// Null while unknown, and for live streams.
  final Duration? duration;

  @override
  bool operator ==(Object other) =>
      other is PlaybackProgress &&
      other.position == position &&
      other.bufferedPosition == bufferedPosition &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(position, bufferedPosition, duration);

  @override
  String toString() => 'PlaybackProgress($position / $duration, buffered $bufferedPosition)';
}
