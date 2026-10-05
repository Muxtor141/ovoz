import 'package:ovoz/src/session/audio_session_config.dart';
import 'package:ovoz/src/session/session_events.dart';

/// The core engine contract for the app-wide audio session.
abstract interface class SessionEngine {
  /// Returns null on success, or why the system refused.
  String? configure(AudioSessionConfig config);

  /// Returns null on success, or why the system refused.
  String? setActive(bool active);

  bool get hasAudioBackgroundMode;

  Stream<SessionEvent> get events;
}
