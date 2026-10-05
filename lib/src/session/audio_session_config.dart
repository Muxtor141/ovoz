import 'package:flutter/foundation.dart';

/// iOS audio session categories. The order is part of the platform contract.
enum SessionCategory {
  /// Plays with the silent switch on and in the background; silences other
  /// apps unless mixing is allowed.
  playback,

  /// Mixes with other apps, obeys the silent switch, stops in the background.
  ambient,

  /// Like [ambient] but silences other apps.
  soloAmbient,

  /// Playback while recording.
  playAndRecord,
}

/// iOS audio session modes. The order is part of the platform contract.
enum SessionMode {
  /// The system default.
  standard,

  /// Audiobooks and podcasts: other apps' spoken prompts pause this audio
  /// instead of ducking it.
  spokenAudio,
  moviePlayback,
  voicePrompt,
}

/// Category options. The order is part of the platform contract.
enum SessionOption {
  mixWithOthers,
  duckOthers,
  interruptSpokenAudioAndMixWithOthers,
  allowBluetoothA2dp,
  allowAirPlay,
  defaultToSpeaker,
  allowBluetoothHfp,
}

enum RouteSharingPolicy {
  standard,

  /// Routes to the same output as other long-form audio apps (music,
  /// podcasts, audiobooks), for example AirPlay speakers.
  longFormAudio,
}

/// What happens to players when another app or a call takes the audio
/// (SES-04).
enum InterruptionPolicy {
  /// Pause, and resume when the interruption ends if the system says so.
  pauseAndResume,

  /// Pause and stay paused.
  pauseOnly,

  /// Leave it to the app, which listens to [AudioSession.interruptions].
  /// Players still report that the system paused them.
  none,
}

/// The app-wide audio session configuration (D-14).
///
/// Presets are plain configurations (P-02): inspect them, and change any
/// field with [copyWith].
@immutable
final class AudioSessionConfig {
  const AudioSessionConfig({
    this.category = SessionCategory.playback,
    this.mode = SessionMode.standard,
    this.options = const {},
    this.routeSharingPolicy = RouteSharingPolicy.standard,
    this.interruptionPolicy = InterruptionPolicy.pauseAndResume,
    this.pauseOnBecomingNoisy = true,
    this.deactivateWhenIdle = false,
    this.managedByApp = false,
  });

  /// Music and general playback; takes audio focus. The default (SES-09).
  const AudioSessionConfig.music() : this();

  /// Audiobooks, podcasts, lessons. Matches what Mutolaa configures today.
  const AudioSessionConfig.speech() : this(mode: SessionMode.spokenAudio);

  /// Sound effects and ambience that mix with other apps and respect the
  /// silent switch. No background playback.
  const AudioSessionConfig.ambient() : this(category: SessionCategory.ambient, pauseOnBecomingNoisy: false);

  /// The app (or another audio plugin) manages the session; players only
  /// observe interruptions and route changes so their state stays correct
  /// (SES-07).
  const AudioSessionConfig.managedByApp() : this(managedByApp: true);

  final SessionCategory category;
  final SessionMode mode;
  final Set<SessionOption> options;
  final RouteSharingPolicy routeSharingPolicy;
  final InterruptionPolicy interruptionPolicy;

  /// Pause when headphones are unplugged.
  final bool pauseOnBecomingNoisy;

  /// Deactivate the session a moment after every player has stopped
  /// playing, so other apps' audio resumes.
  final bool deactivateWhenIdle;

  /// See [AudioSessionConfig.managedByApp].
  final bool managedByApp;

  /// Whether audio in this configuration can continue in the background.
  bool get supportsBackground =>
      category == SessionCategory.playback || category == SessionCategory.playAndRecord;

  AudioSessionConfig copyWith({
    SessionCategory? category,
    SessionMode? mode,
    Set<SessionOption>? options,
    RouteSharingPolicy? routeSharingPolicy,
    InterruptionPolicy? interruptionPolicy,
    bool? pauseOnBecomingNoisy,
    bool? deactivateWhenIdle,
    bool? managedByApp,
  }) => AudioSessionConfig(
    category: category ?? this.category,
    mode: mode ?? this.mode,
    options: options ?? this.options,
    routeSharingPolicy: routeSharingPolicy ?? this.routeSharingPolicy,
    interruptionPolicy: interruptionPolicy ?? this.interruptionPolicy,
    pauseOnBecomingNoisy: pauseOnBecomingNoisy ?? this.pauseOnBecomingNoisy,
    deactivateWhenIdle: deactivateWhenIdle ?? this.deactivateWhenIdle,
    managedByApp: managedByApp ?? this.managedByApp,
  );

  @override
  bool operator ==(Object other) =>
      other is AudioSessionConfig &&
      other.category == category &&
      other.mode == mode &&
      setEquals(other.options, options) &&
      other.routeSharingPolicy == routeSharingPolicy &&
      other.interruptionPolicy == interruptionPolicy &&
      other.pauseOnBecomingNoisy == pauseOnBecomingNoisy &&
      other.deactivateWhenIdle == deactivateWhenIdle &&
      other.managedByApp == managedByApp;

  @override
  int get hashCode => Object.hash(
    category,
    mode,
    Object.hashAllUnordered(options),
    routeSharingPolicy,
    interruptionPolicy,
    pauseOnBecomingNoisy,
    deactivateWhenIdle,
    managedByApp,
  );

  @override
  String toString() =>
      'AudioSessionConfig(${category.name}, ${mode.name}, ${options.map((o) => o.name).join('|')})';
}
