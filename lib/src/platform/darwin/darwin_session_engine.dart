import 'dart:async';

// toDartString() on the NSStrings the session returns.
import 'package:objective_c/objective_c.dart';

import 'package:ovoz/src/engine/session_engine.dart';
import 'package:ovoz/src/platform/darwin/ovoz_bindings.g.dart';
import 'package:ovoz/src/session/audio_session_config.dart';
import 'package:ovoz/src/session/session_events.dart';

/// [SessionEngine] on the Swift engine's `OvozSession`.
final class DarwinSessionEngine implements SessionEngine {
  DarwinSessionEngine() {
    final listener = OvozSessionListener$Builder.implementAsListener(
      onInterruption_shouldResume_: (began, shouldResume) =>
          _events.add(AudioInterruption(began: began, shouldResume: shouldResume)),
      onBecomingNoisy: () => _events.add(const BecomingNoisy()),
      onRouteChanged_: (reason) => _events.add(
        AudioRouteChange(
          reason >= 0 && reason < AudioRouteChangeReason.values.length
              ? AudioRouteChangeReason.values[reason]
              : AudioRouteChangeReason.unknown,
        ),
      ),
      onMediaServicesReset: () => _events.add(const MediaServicesReset()),
      $keepIsolateAlive: false,
    );
    _session.setListener(listener);
  }

  final OvozSession _session = OvozSession.getShared();
  final _events = StreamController<SessionEvent>.broadcast();

  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  String? configure(AudioSessionConfig config) {
    var options = 0;
    for (final option in config.options) {
      options |= 1 << option.index;
    }
    return _session
        .configureWithManaged(
          !config.managedByApp,
          category: config.category.index,
          mode: config.mode.index,
          options: options,
          routeSharingPolicy: config.routeSharingPolicy.index,
          interruptionPolicy: config.interruptionPolicy.index,
          pauseOnBecomingNoisy: config.pauseOnBecomingNoisy,
          deactivateWhenIdle: config.deactivateWhenIdle,
        )
        ?.toDartString();
  }

  @override
  String? setActive(bool active) => _session.setActive(active)?.toDartString();

  @override
  bool get hasAudioBackgroundMode => _session.hasAudioBackgroundMode;
}
