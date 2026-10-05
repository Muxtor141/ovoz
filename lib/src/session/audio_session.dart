import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:ovoz/src/audio_error.dart';
import 'package:ovoz/src/engine/session_engine.dart';
import 'package:ovoz/src/platform/engines.dart';
import 'package:ovoz/src/session/audio_session_config.dart';
import 'package:ovoz/src/session/session_events.dart';

/// The app's audio session: how its audio coexists with other apps, calls and
/// the system (D-14). One per app, shared by every [AudioPlayer]; players
/// never configure it themselves (SES-01).
///
/// Nothing touches the system session until the first player plays; then the
/// [config] is applied — [AudioSessionConfig.music] unless configured
/// otherwise (SES-09).
final class AudioSession {
  AudioSession._(this._engine) {
    _subscription = _engine.events.listen(_events.add);
  }

  static AudioSession? _instance;

  /// The session. Created on first use.
  static AudioSession get instance => _instance ??= AudioSession._(createSessionEngine());

  /// Replaces the session's engine, for tests.
  @visibleForTesting
  static void debugUseEngine(SessionEngine engine) {
    _instance?._dispose();
    _instance = AudioSession._(engine);
  }

  final SessionEngine _engine;
  final _events = StreamController<SessionEvent>.broadcast();
  StreamSubscription<SessionEvent>? _subscription;

  AudioSessionConfig _config = const AudioSessionConfig.music();

  AudioSessionConfig get config => _config;

  /// Applies [config], now if audio is already playing, otherwise at the next
  /// play. May be called again at any time (SES-06).
  Future<void> configure(AudioSessionConfig config) async {
    final error = _engine.configure(config);
    if (error != null) throw AudioSessionException(error);
    _config = config;
  }

  /// Activates or deactivates the session explicitly. Players activate it on
  /// their own; this is for apps managing the session themselves, and for
  /// handing audio back to other apps early.
  Future<void> setActive(bool active) async {
    final error = _engine.setActive(active);
    if (error != null) throw AudioSessionException(error);
  }

  /// Whether the app's Info.plist declares the `audio` background mode, which
  /// playback with the screen off needs (D-16).
  bool get hasAudioBackgroundMode => _engine.hasAudioBackgroundMode;

  /// Every session event.
  Stream<SessionEvent> get events => _events.stream;

  Stream<AudioInterruption> get interruptions => events.where((e) => e is AudioInterruption).cast();

  /// Headphones were unplugged.
  Stream<BecomingNoisy> get becomingNoisy => events.where((e) => e is BecomingNoisy).cast();

  Stream<AudioRouteChange> get routeChanges => events.where((e) => e is AudioRouteChange).cast();

  void _dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_events.close());
  }
}
