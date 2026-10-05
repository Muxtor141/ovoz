import 'package:flutter/foundation.dart';

/// Commands the lock screen, Control Center, headsets and cars can send.
///
/// The order is part of the platform contract: do not reorder.
enum MediaCommand {
  play,
  pause,
  togglePlayPause,
  stop,
  next,
  previous,

  /// Scrubbing on the lock screen.
  seek,
  skipForward,
  skipBackward,
  changeSpeed,
}

/// A command as it arrived, with its argument.
@immutable
final class MediaCommandEvent {
  const MediaCommandEvent(this.command, {this.position, this.interval, this.speed});

  final MediaCommand command;

  /// For [MediaCommand.seek].
  final Duration? position;

  /// For [MediaCommand.skipForward] and [MediaCommand.skipBackward].
  final Duration? interval;

  /// For [MediaCommand.changeSpeed].
  final double? speed;

  @override
  String toString() => 'MediaCommandEvent(${command.name})';
}

/// Return true when the app handled [event] itself, false to let the player
/// apply it.
typedef MediaCommandHandler = bool Function(MediaCommandEvent event);

/// Puts a player on the lock screen and in Control Center, controllable from
/// headsets and cars (BG-01). Requires the `audio` background mode in the
/// app's Info.plist for playback to continue with the screen off.
///
/// Only one player at a time owns these controls: enabling them on a player
/// takes them from any other.
@immutable
final class MediaControls {
  const MediaControls({
    this.commands = defaultCommands,
    this.skipInterval = const Duration(seconds: 15),
    this.onCommand,
  });

  static const Set<MediaCommand> defaultCommands = {
    MediaCommand.play,
    MediaCommand.pause,
    MediaCommand.togglePlayPause,
    MediaCommand.next,
    MediaCommand.previous,
    MediaCommand.seek,
  };

  /// Typical for audiobooks and podcasts. On iOS the lock screen shows skip
  /// buttons instead of next/previous when both are enabled.
  static const Set<MediaCommand> spokenWordCommands = {
    MediaCommand.play,
    MediaCommand.pause,
    MediaCommand.togglePlayPause,
    MediaCommand.skipForward,
    MediaCommand.skipBackward,
    MediaCommand.seek,
  };

  final Set<MediaCommand> commands;

  /// For [MediaCommand.skipForward] and [MediaCommand.skipBackward].
  final Duration skipInterval;

  /// Sees every command first; see [MediaCommandHandler].
  final MediaCommandHandler? onCommand;
}
