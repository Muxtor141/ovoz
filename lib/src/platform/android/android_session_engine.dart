import 'dart:async';

import 'package:jni/jni.dart';

import 'package:ovoz/src/engine/session_engine.dart';
import 'package:ovoz/src/platform/android/ovoz_bindings.g.dart';
import 'package:ovoz/src/session/audio_session_config.dart';
import 'package:ovoz/src/session/session_events.dart';

/// [SessionEngine] on the Kotlin engine's `OvozSession`: audio attributes and
/// audio focus.
final class AndroidSessionEngine implements SessionEngine {
  AndroidSessionEngine() {
    final listener = OvozSessionListener.implement(
      $OvozSessionListener(
        onInterruption: (began, shouldResume) =>
            _events.add(AudioInterruption(began: began, shouldResume: shouldResume)),
        onInterruption$async: true,
        onBecomingNoisy: () => _events.add(const BecomingNoisy()),
        onBecomingNoisy$async: true,
        onRouteChanged: (reason) => _events.add(
          AudioRouteChange(
            reason >= 0 && reason < AudioRouteChangeReason.values.length
                ? AudioRouteChangeReason.values[reason]
                : AudioRouteChangeReason.unknown,
          ),
        ),
        onRouteChanged$async: true,
        onMediaServicesReset: () => _events.add(const MediaServicesReset()),
        onMediaServicesReset$async: true,
      ),
    );
    _session.listener = listener;
    listener.release();
  }

  final OvozSession _session = OvozSession.INSTANCE;
  final _events = StreamController<SessionEvent>.broadcast();

  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  String? configure(AudioSessionConfig config) {
    final android = config.effectiveAndroidAudio;
    return _session
        .configure(
          !config.managedByApp,
          android.usage.index,
          android.contentType.index,
          android.focus.index,
          android.pauseWhenDucked,
          config.interruptionPolicy.index,
          config.pauseOnBecomingNoisy,
          config.deactivateWhenIdle,
        )
        ?.toDartString(releaseOriginal: true);
  }

  @override
  String? setActive(bool active) => _session.setActive(active)?.toDartString(releaseOriginal: true);

  @override
  bool get hasAudioBackgroundMode => _session.hasAudioBackgroundMode;
}
