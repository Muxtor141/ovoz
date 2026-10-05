/// Audio playback with native-owned players: queues, gapless transitions,
/// encrypted sources decrypted in memory, an app-wide audio session and
/// lock-screen controls.
///
/// ```dart
/// import 'package:ovoz/ovoz.dart';
///
/// final player = AudioPlayer();
/// await player.setQueue([AudioSource.url(Uri.parse('https://…/1.mp3')), …]);
/// await player.play();
/// ```
library;

export 'src/audio_error.dart'
    show AudioError, AudioErrorKind, AudioSessionException, LoadInterruptedException;
export 'src/audio_player.dart' show AudioPlayer;
export 'src/audio_source.dart' show AesCtrEncryption, AudioFormat, AudioSource, ClipRange, MediaMetadata;
export 'src/media_controls.dart' show MediaCommand, MediaCommandEvent, MediaCommandHandler, MediaControls;
export 'src/player_event.dart' show ItemCompleted, ItemFailed, PlayerEvent;
export 'src/player_options.dart' show PlayerOptions;
export 'src/player_state.dart' show LoopMode, PitchCorrection, PlaybackProgress, PlayerState, ProcessingState;
export 'src/queue/play_queue.dart' show QueueState;
export 'src/session/audio_session.dart' show AudioSession;
export 'src/session/audio_session_config.dart'
    show
        AudioSessionConfig,
        InterruptionPolicy,
        RouteSharingPolicy,
        SessionCategory,
        SessionMode,
        SessionOption;
export 'src/session/session_events.dart'
    show
        AudioInterruption,
        AudioRouteChange,
        AudioRouteChangeReason,
        BecomingNoisy,
        MediaServicesReset,
        SessionEvent;
