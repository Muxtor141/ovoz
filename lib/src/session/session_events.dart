import 'package:flutter/foundation.dart';

/// Something the system did to the app's audio.
@immutable
sealed class SessionEvent {
  const SessionEvent();
}

/// A call, an alarm or another app took the audio ([began]), or gave it
/// back. Players have already been paused (or resumed) per the
/// [InterruptionPolicy].
final class AudioInterruption extends SessionEvent {
  const AudioInterruption({required this.began, required this.shouldResume});

  final bool began;

  /// On the end of an interruption: whether the system suggests resuming.
  final bool shouldResume;

  @override
  String toString() => 'AudioInterruption(${began ? 'began' : 'ended'}${shouldResume ? ', resume' : ''})';
}

/// Headphones were unplugged: audio was about to come out of the speaker.
final class BecomingNoisy extends SessionEvent {
  const BecomingNoisy();

  @override
  String toString() => 'BecomingNoisy()';
}

/// Why the audio route changed.
enum AudioRouteChangeReason {
  unknown,
  newDeviceAvailable,
  oldDeviceUnavailable,
  categoryChange,
  override,
  wakeFromSleep,
  noSuitableRouteForCategory,
  routeConfigurationChange,
}

final class AudioRouteChange extends SessionEvent {
  const AudioRouteChange(this.reason);

  final AudioRouteChangeReason reason;

  @override
  String toString() => 'AudioRouteChange(${reason.name})';
}

/// The system's media services restarted. Rare; players may need to load
/// their sources again.
final class MediaServicesReset extends SessionEvent {
  const MediaServicesReset();

  @override
  String toString() => 'MediaServicesReset()';
}
