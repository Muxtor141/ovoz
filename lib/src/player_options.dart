import 'package:flutter/foundation.dart';

import 'package:ovoz/src/player_state.dart';

/// How an [AudioPlayer] behaves. Every default can be changed (P-03).
@immutable
final class PlayerOptions {
  const PlayerOptions({
    this.positionInterval = const Duration(milliseconds: 200),
    this.previousRestartThreshold = const Duration(seconds: 3),
    this.maxSkipsOnError = 0,
    this.pitchCorrection = PitchCorrection.speech,
    this.stallPolicy,
  });

  /// How often [AudioPlayer.positionStream] and
  /// [AudioPlayer.progressStream] read the position while someone listens
  /// (EVT-03). Nothing is read while nobody listens.
  final Duration positionInterval;

  /// [AudioPlayer.skipToPrevious] restarts the current item when more than
  /// this has played, and goes to the previous item otherwise (PL-05).
  /// [Duration.zero] always goes to the previous item.
  final Duration previousRestartThreshold;

  /// How many failing items in a row the player skips before it stops and
  /// waits (PL-06). 0 stops at the first failure.
  final int maxSkipsOnError;

  /// The initial pitch correction for speed changes.
  final PitchCorrection pitchCorrection;

  /// The initial [AudioPlayer.stallPolicy]. None by default: the player waits
  /// for audio as long as the platform does.
  final StallPolicy? stallPolicy;
}

/// What a player does when it waits for audio it should be playing: a
/// connection that went quiet, or a load that never finishes.
///
/// A wait is time without audio, [ProcessingState.loading] or
/// [ProcessingState.buffering], while the player is playing or a
/// [AudioPlayer.setSource] waits for the item. It ends when audio plays or
/// nobody waits any more (a pause, say); moving to another item starts a new
/// one.
@immutable
final class StallPolicy {
  const StallPolicy({this.reconnectAfter, required this.giveUpAfter});

  /// After waiting this long, the player loads the item again where it is, so
  /// that it reads over new connections. Once per wait; null never does.
  final Duration? reconnectAfter;

  /// After waiting this long in all, the player gives up: the item fails with
  /// [AudioErrorKind.network] ([ItemFailed]) and the player is idle at its
  /// position, as after any failure, so [AudioPlayer.play] tries again.
  final Duration giveUpAfter;

  @override
  bool operator ==(Object other) =>
      other is StallPolicy && other.reconnectAfter == reconnectAfter && other.giveUpAfter == giveUpAfter;

  @override
  int get hashCode => Object.hash(reconnectAfter, giveUpAfter);
}
