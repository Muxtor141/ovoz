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

/// What the app's audio is for, as Android's audio attributes say it. The
/// order is part of the platform contract.
enum AndroidAudioUsage {
  media,
  game,
  assistanceSonification,
  navigationGuidance,
  assistant,
  notification,
  alarm,
  voiceCommunication,
}

/// What the app's audio contains, as Android's audio attributes say it. The
/// order is part of the platform contract.
enum AndroidAudioContentType { music, speech, movie, sonification, unknown }

/// How the session takes audio focus on Android, which decides what other
/// apps do while it plays. The order is part of the platform contract.
enum AndroidAudioFocus {
  /// Other apps stop for as long as this app plays: music, audiobooks.
  gain,

  /// Other apps pause for a moment: a voice message.
  gainTransient,

  /// Other apps lower their volume, or pause if they speak: navigation
  /// prompts, short effects over someone else's music.
  gainTransientMayDuck,

  /// No focus: plays alongside other apps and is never interrupted by them.
  none,
}

/// The Android side of an [AudioSessionConfig]: audio attributes and audio
/// focus (SES-03).
@immutable
final class AndroidAudioConfig {
  const AndroidAudioConfig({
    this.usage = AndroidAudioUsage.media,
    this.contentType = AndroidAudioContentType.music,
    this.focus = AndroidAudioFocus.gain,
    this.pauseWhenDucked = false,
  });

  final AndroidAudioUsage usage;
  final AndroidAudioContentType contentType;
  final AndroidAudioFocus focus;

  /// Pause, rather than have the system lower the volume, when another app
  /// speaks over this one. Right for speech, which is hard to follow ducked.
  final bool pauseWhenDucked;

  AndroidAudioConfig copyWith({
    AndroidAudioUsage? usage,
    AndroidAudioContentType? contentType,
    AndroidAudioFocus? focus,
    bool? pauseWhenDucked,
  }) => AndroidAudioConfig(
    usage: usage ?? this.usage,
    contentType: contentType ?? this.contentType,
    focus: focus ?? this.focus,
    pauseWhenDucked: pauseWhenDucked ?? this.pauseWhenDucked,
  );

  @override
  bool operator ==(Object other) =>
      other is AndroidAudioConfig &&
      other.usage == usage &&
      other.contentType == contentType &&
      other.focus == focus &&
      other.pauseWhenDucked == pauseWhenDucked;

  @override
  int get hashCode => Object.hash(usage, contentType, focus, pauseWhenDucked);

  @override
  String toString() =>
      'AndroidAudioConfig(${usage.name}, ${contentType.name}, focus: ${focus.name}'
      '${pauseWhenDucked ? ', pause when ducked' : ''})';
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
    this.androidAudio,
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

  /// Android's audio attributes and audio focus. Null derives them from the
  /// fields above; [effectiveAndroidAudio] says what that gives.
  final AndroidAudioConfig? androidAudio;

  /// What the session uses on Android: [androidAudio], or, without one:
  ///
  /// - [SessionMode.spokenAudio]: speech, paused (not ducked) when another app
  ///   speaks over it;
  /// - [SessionMode.moviePlayback]: movie content;
  /// - [SessionCategory.ambient] or [SessionOption.mixWithOthers]: no focus,
  ///   so it plays alongside other apps;
  /// - [SessionOption.duckOthers] or
  ///   [SessionOption.interruptSpokenAudioAndMixWithOthers]: transient focus
  ///   that lets other apps duck, or pause if they speak;
  /// - otherwise music, with focus that stops other apps.
  AndroidAudioConfig get effectiveAndroidAudio {
    if (androidAudio case final explicit?) return explicit;
    final spoken = mode == SessionMode.spokenAudio;
    return AndroidAudioConfig(
      contentType: switch (mode) {
        SessionMode.spokenAudio => AndroidAudioContentType.speech,
        SessionMode.moviePlayback => AndroidAudioContentType.movie,
        _ => AndroidAudioContentType.music,
      },
      focus: category == SessionCategory.ambient || options.contains(SessionOption.mixWithOthers)
          ? AndroidAudioFocus.none
          : options.contains(SessionOption.duckOthers) ||
                options.contains(SessionOption.interruptSpokenAudioAndMixWithOthers)
          ? AndroidAudioFocus.gainTransientMayDuck
          : AndroidAudioFocus.gain,
      pauseWhenDucked: spoken,
    );
  }

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
    AndroidAudioConfig? androidAudio,
  }) => AudioSessionConfig(
    category: category ?? this.category,
    mode: mode ?? this.mode,
    options: options ?? this.options,
    routeSharingPolicy: routeSharingPolicy ?? this.routeSharingPolicy,
    interruptionPolicy: interruptionPolicy ?? this.interruptionPolicy,
    pauseOnBecomingNoisy: pauseOnBecomingNoisy ?? this.pauseOnBecomingNoisy,
    deactivateWhenIdle: deactivateWhenIdle ?? this.deactivateWhenIdle,
    managedByApp: managedByApp ?? this.managedByApp,
    androidAudio: androidAudio ?? this.androidAudio,
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
      other.managedByApp == managedByApp &&
      other.androidAudio == androidAudio;

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
    androidAudio,
  );

  @override
  String toString() =>
      'AudioSessionConfig(${category.name}, ${mode.name}, ${options.map((o) => o.name).join('|')})';
}
