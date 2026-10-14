package uz.sayma.ovoz.engine

// Values shared with Dart's enums, which travel as their indices. The order
// is part of the contract with lib/src/platform/android/.

/** Dart's `ProcessingState`. */
internal object ProcessingState {
  const val IDLE = 0
  const val LOADING = 1
  const val BUFFERING = 2
  const val READY = 3
  const val COMPLETED = 4
}

/** Dart's `PitchCorrection`. */
internal object PitchCorrection {
  const val SPEECH = 0
  const val MUSIC = 1
  const val NONE = 2
}

/**
 * Dart's `MediaCommand`: commands the notification, the lock screen, headsets
 * and cars can send. As bit positions they also form the set passed to
 * `enableMediaControls`.
 */
internal object RemoteCommand {
  const val PLAY = 0
  const val PAUSE = 1
  const val TOGGLE_PLAY_PAUSE = 2
  const val STOP = 3
  const val NEXT = 4
  const val PREVIOUS = 5
  const val SEEK = 6
  const val SKIP_FORWARD = 7
  const val SKIP_BACKWARD = 8
  const val CHANGE_RATE = 9
}

/** Dart's `AudioRouteChangeReason`. */
internal object RouteChangeReason {
  const val NEW_DEVICE_AVAILABLE = 1
  const val OLD_DEVICE_UNAVAILABLE = 2
}
