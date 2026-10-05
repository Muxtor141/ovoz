import 'dart:async';

import 'package:ovoz/src/engine/session_engine.dart';
import 'package:ovoz/src/session/audio_session_config.dart';
import 'package:ovoz/src/session/session_events.dart';

/// A [SessionEngine] that records configurations and lets tests send the
/// system's events.
class FakeSessionEngine implements SessionEngine {
  FakeSessionEngine({this.hasAudioBackgroundMode = true});

  @override
  final bool hasAudioBackgroundMode;

  final List<AudioSessionConfig> configurations = [];
  bool active = false;

  /// When set, [configure] refuses with this message.
  String? refuseWith;

  final _events = StreamController<SessionEvent>.broadcast();

  @override
  Stream<SessionEvent> get events => _events.stream;

  void send(SessionEvent event) => _events.add(event);

  @override
  String? configure(AudioSessionConfig config) {
    if (refuseWith != null) return refuseWith;
    configurations.add(config);
    return null;
  }

  @override
  String? setActive(bool active) {
    this.active = active;
    return null;
  }
}
