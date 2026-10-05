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
}
