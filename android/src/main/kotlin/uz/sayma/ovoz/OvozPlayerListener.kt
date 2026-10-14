package uz.sayma.ovoz

import androidx.annotation.Keep

/**
 * Native events for one player, implemented in Dart (EVT-01).
 *
 * Every method is called on the main thread and implemented in Dart as a
 * listener: the call is posted to the Dart isolate and returns at once.
 * Values that change continuously (position, buffered position) are not
 * pushed; Dart reads them synchronously (EVT-03).
 */
@Keep
interface OvozPlayerListener {
  /**
   * [state] is a Dart `ProcessingState` index; [playing] is whether playback
   * is wanted, which stays true while loading or buffering.
   */
  fun onStateChanged(state: Int, playing: Boolean)

  /**
   * Item [itemId] became current: loaded by `setItem`, or reached by
   * advancing into the cued next item.
   */
  fun onItemStarted(itemId: Long)

  /** Item [itemId] played to its end. Never sent for an item that was replaced, skipped or stopped. */
  fun onItemEnded(itemId: Long)

  fun onDurationChanged(itemId: Long, durationMs: Long)

  /** [code] is a Dart `AudioErrorKind` index. */
  fun onError(itemId: Long, code: Int, message: String)

  /**
   * A notification, lock-screen, headset or car command, for the player that
   * owns the media controls. [command] is a Dart `MediaCommand` index;
   * [value] carries the position or interval in milliseconds, or the rate.
   */
  fun onRemoteCommand(command: Int, value: Double)

  /**
   * The network came back, went away, or moved to another interface (Wi-Fi
   * to cellular): [available] is whether there is one now.
   */
  fun onNetworkChanged(available: Boolean)
}
