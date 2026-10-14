package uz.sayma.ovoz.engine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.core.content.ContextCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.audio.AudioFocusRequestCompat
import androidx.media3.common.audio.AudioManagerCompat
import androidx.media3.common.util.UnstableApi
import uz.sayma.ovoz.OvozPlayer
import uz.sayma.ovoz.OvozSessionListener

/**
 * The app-wide audio session (D-14, SES-01…SES-09), on Android: audio
 * attributes, audio focus, headphones unplugged, and output devices.
 *
 * Audio focus is held by the app as a whole, not by each player: Android
 * tracks focus per request, so two players requesting it on their own would
 * take it from each other. Players never touch focus; they tell the manager
 * when they are about to play, and it requests focus then (lazily: nothing
 * happens until the first play, SES-09). Focus changes become the configured
 * behaviour for every player, the way iOS interruptions do.
 */
@UnstableApi
internal object SessionManager {
  /** Raw values are shared with Dart's `InterruptionPolicy`. */
  enum class InterruptionPolicy { PAUSE_AND_RESUME, PAUSE_ONLY, NONE }

  /** Raw values are shared with Dart's `AndroidAudioFocus`. */
  enum class Focus { GAIN, GAIN_TRANSIENT, GAIN_TRANSIENT_MAY_DUCK, NONE }

  data class Config(
    /** False: the app manages audio focus itself (SES-07). */
    val managed: Boolean = true,
    val usage: Int = C.USAGE_MEDIA,
    val contentType: Int = C.AUDIO_CONTENT_TYPE_MUSIC,
    val focus: Focus = Focus.GAIN,
    /** Pause, rather than be ducked, when another app speaks over this one. */
    val pauseWhenDucked: Boolean = false,
    val interruptionPolicy: InterruptionPolicy = InterruptionPolicy.PAUSE_AND_RESUME,
    val pauseOnBecomingNoisy: Boolean = true,
    val deactivateWhenIdle: Boolean = false,
  )

  var config = Config()
    private set

  var listener: OvozSessionListener? = null

  private val players = LinkedHashSet<OvozPlayer>()
  private var focusRequest: AudioFocusRequestCompat? = null

  /**
   * Whether the app holds focus now. False during a transient loss too,
   * while [focusRequest] stays registered to hear focus come back.
   */
  private var hasFocus = false

  /**
   * One listener for every request: Android tells focus requests apart by
   * their listener, and two of the app's own would take focus from each
   * other.
   */
  private val focusListener = AudioManager.OnAudioFocusChangeListener { focusChanged(it) }

  /** Players a transient focus loss paused, to resume when focus returns. */
  private var interrupted: List<OvozPlayer> = emptyList()

  /** A transient loss was reported to the app, and its end is still to come. */
  private var interruptionReported = false

  /**
   * Another app speaks over this one and the system does not lower our
   * volume itself (it does from Android 8 on, unless we asked to pause), so
   * every player plays quieter until focus comes back.
   */
  var ducked = false
    private set
  private var deactivation: Runnable? = null
  private var watching = false

  val audioAttributes: AudioAttributes
    get() = AudioAttributes.Builder().setUsage(config.usage).setContentType(config.contentType).build()

  private val audioManager: AudioManager
    get() = Ovoz.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

  fun register(player: OvozPlayer) {
    players += player
    watchSystem()
  }

  fun unregister(player: OvozPlayer) {
    players -= player
    interrupted = interrupted - player
    playerStateChanged()
  }

  // ── Configuration ────────────────────────────────────────────────────

  /** Applies [next] now if focus is held, otherwise at the next play (SES-06). */
  fun configure(next: Config) {
    val changedFocus = next.focus != config.focus || next.pauseWhenDucked != config.pauseWhenDucked ||
      next.usage != config.usage || next.contentType != config.contentType || next.managed != config.managed
    config = next
    players.forEach { it.audioAttributesChanged() }
    if (!changedFocus) return
    // During an interruption the request stays, to hear focus come back; the
    // new focus settings apply from the next request.
    if (focusRequest != null && !hasFocus) return
    val held = hasFocus
    abandonFocus()
    if (held && next.managed && players.any { it.wantsPlayback }) requestFocus()
  }

  /** Requests or abandons focus explicitly. Returns false when the system refused. */
  fun setActive(active: Boolean): Boolean {
    if (!active) {
      abandonFocus()
      return true
    }
    return requestFocus()
  }

  // ── Called by players ────────────────────────────────────────────────

  /**
   * A player is about to start: request focus if the package manages it
   * (SES-05). Returns false when the system refused (a call is going on): the
   * player then stays paused.
   */
  fun playerWillPlay(): Boolean {
    cancelDeactivation()
    if (!config.managed || config.focus == Focus.NONE || hasFocus) return true
    if (requestFocus()) return true
    Ovoz.warn("ovoz: the system refused audio focus; not playing")
    listener?.onInterruption(true, false)
    return false
  }

  /** Abandons focus once nothing plays, when configured to (SES-05). */
  fun playerStateChanged() {
    if (!config.managed || !config.deactivateWhenIdle || !hasFocus) return
    if (players.any { it.wantsPlayback }) {
      cancelDeactivation()
      return
    }
    if (deactivation != null) return
    val work = Runnable {
      deactivation = null
      // Not during an interruption: an abandoned request never hears focus
      // come back, and the players it paused would not resume.
      if (hasFocus && interrupted.isEmpty() && players.none { it.wantsPlayback }) abandonFocus()
    }
    deactivation = work
    Ovoz.mainHandler.postDelayed(work, 2_000)
  }

  private fun cancelDeactivation() {
    deactivation?.let { Ovoz.mainHandler.removeCallbacks(it) }
    deactivation = null
  }

  // ── Audio focus ──────────────────────────────────────────────────────

  private fun requestFocus(): Boolean {
    if (config.focus == Focus.NONE || hasFocus) return true
    val gain = when (config.focus) {
      Focus.GAIN_TRANSIENT -> AudioManagerCompat.AUDIOFOCUS_GAIN_TRANSIENT
      Focus.GAIN_TRANSIENT_MAY_DUCK -> AudioManagerCompat.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
      else -> AudioManagerCompat.AUDIOFOCUS_GAIN
    }
    val request = AudioFocusRequestCompat.Builder(gain)
      .setAudioAttributes(audioAttributes)
      .setWillPauseWhenDucked(config.pauseWhenDucked)
      .setOnAudioFocusChangeListener(focusListener, Ovoz.mainHandler)
      .build()
    val granted = AudioManagerCompat.requestAudioFocus(audioManager, request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    if (granted) {
      focusRequest = request
      hasFocus = true
      setDucked(false)
    }
    return granted
  }

  private fun abandonFocus() {
    cancelDeactivation()
    focusRequest?.let { AudioManagerCompat.abandonAudioFocusRequest(audioManager, it) }
    focusRequest = null
    hasFocus = false
    setDucked(false)
  }

  private fun setDucked(value: Boolean) {
    if (ducked == value) return
    ducked = value
    players.forEach { it.duckingChanged() }
  }

  /** The last Flutter engine went away: give focus back, and forget its listener. */
  fun shutDown() {
    abandonFocus()
    interrupted = emptyList()
    interruptionReported = false
    listener = null
  }

  /**
   * Another app (or a call) took focus, or gave it back. Android silences no
   * one by itself: pausing is ours to do, per the policy. A transient loss is
   * an interruption that ends; a permanent one is not given back, and the
   * next play requests focus again.
   */
  private fun focusChanged(change: Int) {
    when (change) {
      AudioManager.AUDIOFOCUS_LOSS -> {
        abandonFocus()
        interrupted = emptyList()
        interruptionReported = false
        if (config.interruptionPolicy != InterruptionPolicy.NONE) players.toList().forEach { it.interruptionBegan() }
        listener?.onInterruption(true, false)
      }
      AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> transientLoss()
      // From Android 8 on this arrives only when we asked to pause instead of
      // being ducked (setWillPauseWhenDucked); before, it always does, and
      // the system leaves the ducking to us.
      AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> if (config.pauseWhenDucked) transientLoss() else setDucked(true)
      AudioManager.AUDIOFOCUS_GAIN -> {
        hasFocus = true
        setDucked(false)
        val resume = interrupted
        interrupted = emptyList()
        if (config.interruptionPolicy == InterruptionPolicy.PAUSE_AND_RESUME) resume.forEach { it.play() }
        if (interruptionReported) {
          interruptionReported = false
          listener?.onInterruption(false, true)
        }
      }
    }
  }

  private fun transientLoss() {
    // The request stays registered: it is how focus coming back is heard.
    hasFocus = false
    cancelDeactivation()
    // A second loss before focus returns (a duck during a call) adds to the
    // players to resume; it does not forget them.
    if (config.interruptionPolicy != InterruptionPolicy.NONE) {
      interrupted = (interrupted + players.toList().filter { it.interruptionBegan() }).distinct()
    }
    interruptionReported = true
    listener?.onInterruption(true, false)
  }

  // ── Headphones and output devices ────────────────────────────────────

  private fun watchSystem() {
    if (watching) return
    watching = true
    val context = Ovoz.context
    ContextCompat.registerReceiver(
      context,
      object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
          if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) becomingNoisy()
        }
      },
      IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
      ContextCompat.RECEIVER_NOT_EXPORTED,
    )
    audioManager.registerAudioDeviceCallback(object : AudioDeviceCallback() {
      // Registering reports every device already connected: not a change.
      private var initial = true

      override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
        if (initial) {
          initial = false
          return
        }
        if (addedDevices.any { it.isSink }) listener?.onRouteChanged(RouteChangeReason.NEW_DEVICE_AVAILABLE)
      }

      override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
        initial = false
        if (removedDevices.any { it.isSink }) listener?.onRouteChanged(RouteChangeReason.OLD_DEVICE_UNAVAILABLE)
      }
    }, Ovoz.mainHandler)
  }

  /** Headphones unplugged: audio is about to come out of the speaker (BG-05). */
  private fun becomingNoisy() {
    if (config.pauseOnBecomingNoisy) players.filter { it.wantsPlayback }.forEach { it.pause() }
    listener?.onBecomingNoisy()
  }
}
