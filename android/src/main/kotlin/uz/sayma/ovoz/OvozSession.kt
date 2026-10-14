package uz.sayma.ovoz

import androidx.annotation.Keep
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import uz.sayma.ovoz.engine.Ovoz
import uz.sayma.ovoz.engine.SessionManager

/** Session events, implemented in Dart as listeners (posted, never blocking). */
@Keep
interface OvozSessionListener {
  /**
   * Another app or a call took audio focus ([began]), or gave it back. On
   * Android, [shouldResume] is true when focus came back after a transient
   * loss.
   */
  fun onInterruption(began: Boolean, shouldResume: Boolean)

  /** Headphones were unplugged: audio is about to come out of the speaker. */
  fun onBecomingNoisy()

  /** [reason] is a Dart `AudioRouteChangeReason` index. */
  fun onRouteChanged(reason: Int)

  /** Never sent on Android; there for the contract. */
  fun onMediaServicesReset()
}

/**
 * The app-wide audio session, configured from Dart (D-14): audio attributes
 * and audio focus on Android. One per process (`OvozSession.INSTANCE` from
 * Dart).
 *
 * Values travel as Dart enum indices, mapped here.
 */
@Keep
@OptIn(UnstableApi::class)
object OvozSession {
  fun setListener(listener: OvozSessionListener?) {
    Ovoz.checkMainThread()
    SessionManager.listener = listener
  }

  /**
   * [usage], [contentType] and [focus] are Dart `AndroidAudioUsage`,
   * `AndroidAudioContentType` and `AndroidAudioFocus` indices. Returns null
   * on success, or why the configuration was refused.
   */
  fun configure(
    managed: Boolean,
    usage: Int,
    contentType: Int,
    focus: Int,
    pauseWhenDucked: Boolean,
    interruptionPolicy: Int,
    pauseOnBecomingNoisy: Boolean,
    deactivateWhenIdle: Boolean,
  ): String? {
    Ovoz.checkMainThread()
    SessionManager.configure(
      SessionManager.Config(
        managed = managed,
        usage = USAGES.getOrElse(usage) { C.USAGE_MEDIA },
        contentType = CONTENT_TYPES.getOrElse(contentType) { C.AUDIO_CONTENT_TYPE_MUSIC },
        focus = SessionManager.Focus.entries.getOrElse(focus) { SessionManager.Focus.GAIN },
        pauseWhenDucked = pauseWhenDucked,
        interruptionPolicy = SessionManager.InterruptionPolicy.entries.getOrElse(interruptionPolicy) {
          SessionManager.InterruptionPolicy.PAUSE_AND_RESUME
        },
        pauseOnBecomingNoisy = pauseOnBecomingNoisy,
        deactivateWhenIdle = deactivateWhenIdle,
      ),
    )
    return null
  }

  /** Requests (true) or abandons audio focus. Returns null on success, or why it failed. */
  fun setActive(active: Boolean): String? {
    Ovoz.checkMainThread()
    return if (SessionManager.setActive(active)) null else "The system refused audio focus"
  }

  /**
   * Whether the app declares [OvozPlaybackService] as a media-playback
   * foreground service, which playback with the screen off needs (D-16).
   */
  val hasAudioBackgroundMode: Boolean get() = OvozPlaybackService.isDeclared(Ovoz.context)

  // Order matches Dart's AndroidAudioUsage and AndroidAudioContentType.
  private val USAGES = listOf(
    C.USAGE_MEDIA,
    C.USAGE_GAME,
    C.USAGE_ASSISTANCE_SONIFICATION,
    C.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE,
    C.USAGE_ASSISTANT,
    C.USAGE_NOTIFICATION,
    C.USAGE_ALARM,
    C.USAGE_VOICE_COMMUNICATION,
  )
  private val CONTENT_TYPES = listOf(
    C.AUDIO_CONTENT_TYPE_MUSIC,
    C.AUDIO_CONTENT_TYPE_SPEECH,
    C.AUDIO_CONTENT_TYPE_MOVIE,
    C.AUDIO_CONTENT_TYPE_SONIFICATION,
    C.AUDIO_CONTENT_TYPE_UNKNOWN,
  )
}
