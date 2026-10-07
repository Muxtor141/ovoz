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
/// connection that went quiet or dropped, a load that never finishes, the
/// network going away or moving from Wi-Fi to cellular.
///
/// A wait is time without audio, [ProcessingState.loading] or
/// [ProcessingState.buffering], while the player is playing or a
/// [AudioPlayer.setSource] waits for the item. It ends when audio plays or
/// nobody waits any more (a pause, say); moving to another item starts a new
/// one. Throughout, the player stays playing: a pause works as ever.
///
/// With a policy, a connection that fails (an [AudioErrorKind.network] error)
/// is a wait too, not a failure: the player tries the item again shortly, or
/// at once when the network comes back. Without a network nothing is timed,
/// so the player never gives up on a network that is merely gone; when one
/// comes back or the device moves to another, a waiting item is loaded again
/// at once.
@immutable
final class StallPolicy {
  const StallPolicy({this.reconnectAfter, required this.giveUpAfter});

  /// After waiting this long, the player loads the item again where it is, so
  /// that it reads over new connections. Once per wait (the network coming
  /// back, or a failed connection, also reload it); null never does.
  final Duration? reconnectAfter;

  /// After waiting this long with a network, the player gives up: the item
  /// fails with [AudioErrorKind.network] ([ItemFailed]) and the player pauses
  /// where it was, the item still current (on the lock screen too), so
  /// [AudioPlayer.play] loads it again from there.
  final Duration giveUpAfter;

  @override
  bool operator ==(Object other) =>
      other is StallPolicy && other.reconnectAfter == reconnectAfter && other.giveUpAfter == giveUpAfter;

  @override
  int get hashCode => Object.hash(reconnectAfter, giveUpAfter);
}
