package uz.sayma.ovoz

import android.os.Looper
import androidx.annotation.Keep
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import java.io.IOException
import kotlin.math.max
import kotlin.math.min
import uz.sayma.ovoz.engine.LoadedItem
import uz.sayma.ovoz.engine.MediaControls
import uz.sayma.ovoz.engine.NetworkMonitor
import uz.sayma.ovoz.engine.NowPlaying
import uz.sayma.ovoz.engine.Ovoz
import uz.sayma.ovoz.engine.OvozError
import uz.sayma.ovoz.engine.OvozErrors
import uz.sayma.ovoz.engine.OvozLoadErrorPolicy
import uz.sayma.ovoz.engine.PitchCorrection
import uz.sayma.ovoz.engine.ProcessingState
import uz.sayma.ovoz.engine.SessionManager

/**
 * One playback stream (D-17: many may exist), on one ExoPlayer.
 *
 * A mechanism, not a policy: it plays the item it is given, keeps the next
 * item Dart cued ready for a gapless transition, and reports what happens.
 * Which item comes next — order, shuffle, loop, what "previous" means — is
 * decided in Dart, once for every platform. The two-item window is all the
 * native side needs to advance without waiting for Dart (D-04): ExoPlayer's
 * playlist holds the current item and, behind it, the cued one, and the item
 * just finished is removed as soon as it is left.
 *
 * Every method is called on the main thread: Dart runs there (merged
 * UI/platform threads, IO-01), and ExoPlayer is only touched there.
 */
@Keep
@OptIn(UnstableApi::class)
class OvozPlayer(listener: OvozPlayerListener) {
  private var listener: OvozPlayerListener? = listener
  private val exo: ExoPlayer

  private var current: LoadedItem? = null
  private var next: LoadedItem? = null

  /**
   * Whether [next] is in ExoPlayer's playlist. Not while the current item
   * has ended with [pauseAtItemEnd] on: the player stays at the end then, as
   * on iOS, until `play` replays the item or a seek leaves the end.
   */
  private var nextAttached = false

  /** Whether playback is wanted (just_audio's "playing"). */
  private var playWhenReady = false

  /** The current item reached its end and nothing followed it. */
  private var ended = false
  private var endReported: Long? = null

  private var speed = 1f
  private var volume = 1f
  private var pitchCorrection = PitchCorrection.SPEECH
  private var lastState: Pair<Int, Boolean>? = null
  private var lastDuration: Pair<Long, Long>? = null
  private var disposed = false

  // Declared before init, which registers them.
  private val events = object : Player.Listener {
    override fun onPlaybackStateChanged(playbackState: Int) {
      val current = current ?: return
      when (playbackState) {
        Player.STATE_READY -> current.becameReady = true
        Player.STATE_ENDED -> if (!ended && !current.failed) {
          ended = true
          reportEnd(current)
        }
        // Loading, buffering and idle change only the state reported below.
        else -> Unit
      }
      emitDuration()
      syncPlayback()
      emitState()
      updateNowPlaying(seeked = false)
    }

    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
      if (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM) pausedAtItemEnd()
    }

    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
      if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) advanced()
    }

    override fun onTimelineChanged(timeline: Timeline, reason: Int) {
      emitDuration()
      updateNowPlaying(seeked = false)
    }

    override fun onPlayerError(error: PlaybackException) {
      currentFailed(error)
    }
  }

  private val loads = object : AnalyticsListener {
    override fun onLoadError(
      eventTime: AnalyticsListener.EventTime,
      loadEventInfo: LoadEventInfo,
      mediaLoadData: MediaLoadData,
      error: IOException,
      wasCanceled: Boolean,
    ) {
      // A load that will be retried is not a failure yet, nor is one that
      // ExoPlayer restarts later (a stream of unknown length).
      if (!wasCanceled || !OvozLoadErrorPolicy.isFatal(loadEventInfo, mediaLoadData, error)) return
      val cued = next ?: return
      if (mediaIdOf(eventTime) != cued.mediaId) return
      cuedFailed(cued, OvozErrors.classify(error, cued.remote))
    }

    private fun mediaIdOf(eventTime: AnalyticsListener.EventTime): String? {
      val timeline = eventTime.timeline
      if (eventTime.windowIndex < 0 || eventTime.windowIndex >= timeline.windowCount) return null
      return timeline.getWindow(eventTime.windowIndex, Timeline.Window()).mediaItem.mediaId
    }
  }

  init {
    Ovoz.checkMainThread()
    exo = ExoPlayer.Builder(Ovoz.context)
      .setLooper(Looper.getMainLooper())
      // Focus and unplugged headphones are the session's, for every player at once.
      .setAudioAttributes(SessionManager.audioAttributes, false)
      .setHandleAudioBecomingNoisy(false)
      // Keeps the CPU, and Wi-Fi for streams, awake while playing.
      .setWakeMode(C.WAKE_MODE_NETWORK)
      .build()
    exo.addListener(events)
    exo.addAnalyticsListener(loads)
    applyVolume()
    Ovoz.register(this)
    SessionManager.register(this)
    NetworkMonitor.register(this)
  }

  // ── Items ────────────────────────────────────────────────────────────

  /**
   * Makes [item] current, starting at [positionMs] within it (within its
   * clip), and drops any cued item. Keeps playing if playback was wanted.
   * Null empties the player.
   */
  fun setItem(item: OvozItem?, positionMs: Long) {
    Ovoz.checkMainThread()
    if (disposed) return
    clearWindow()
    try {
      if (item == null) return
      when (val made = LoadedItem.make(item)) {
        is LoadedItem.Failed -> {
          // Nothing to show for it: report and stay idle.
          playWhenReady = false
          report(item.itemId, made.error)
        }
        is LoadedItem.Built -> {
          val loaded = made.item
          current = loaded
          listener?.onItemStarted(loaded.id)
          exo.setMediaSource(loaded.mediaSource, max(0, positionMs))
          exo.prepare()
          // Playback may have been wanted before there was anything to play
          // (play, then load): focus is requested now.
          if (playWhenReady && !SessionManager.playerWillPlay()) playWhenReady = false
          syncPlayback()
        }
      }
    } finally {
      updatePauseAtEnd()
      emitState()
      updateNowPlaying(seeked = true)
    }
  }

  /**
   * Cues [item] to follow the current one without a gap; null cues nothing,
   * so the current item ends the stream (or pauses, see [pauseAtItemEnd]).
   */
  fun setNextItem(item: OvozItem?) {
    Ovoz.checkMainThread()
    if (disposed) return
    dropNext()
    try {
      val current = current ?: return
      if (item == null || current.failed) return
      when (val made = LoadedItem.make(item)) {
        is LoadedItem.Failed -> report(item.itemId, made.error)
        is LoadedItem.Built -> {
          next = made.item
          if (!ended) {
            attachNext()
          } else if (!pauseAtItemEnd) {
            advanceFromEnd()
          }
        }
      }
    } finally {
      updatePauseAtEnd()
    }
  }

  /**
   * When true, the end of an item pauses playback instead of continuing; a
   * cued item becomes current, paused at its start ("stop after this
   * chapter").
   */
  var pauseAtItemEnd: Boolean = false
    set(value) {
      Ovoz.checkMainThread()
      field = value
      if (disposed) return
      if (!value && ended && next != null) advanceFromEnd()
      updatePauseAtEnd()
    }

  // ── Transport ────────────────────────────────────────────────────────

  fun play() {
    Ovoz.checkMainThread()
    if (disposed) return
    val current = current
    if (ended && current != null) {
      // Play after the end replays the item, as a play button would.
      ended = false
      exo.seekTo(0, 0)
      attachNext()
    }
    playWhenReady = true
    if (current != null && !SessionManager.playerWillPlay()) playWhenReady = false
    syncPlayback()
    updatePauseAtEnd()
    emitState()
    updateNowPlaying(seeked = false)
  }

  fun pause() {
    Ovoz.checkMainThread()
    if (disposed) return
    playWhenReady = false
    syncPlayback()
    emitState()
    updateNowPlaying(seeked = false)
  }

  /**
   * Releases the items and their decoders. Dart keeps the queue and the
   * position, and sets the item again to resume.
   */
  fun stop() {
    Ovoz.checkMainThread()
    if (disposed) return
    playWhenReady = false
    clearWindow()
    updatePauseAtEnd()
    emitState()
    updateNowPlaying(seeked = true)
  }

  fun seekTo(positionMs: Long) {
    Ovoz.checkMainThread()
    val current = current ?: return
    if (disposed || current.failed) return
    if (ended) {
      ended = false
      attachNext()
    }
    exo.seekTo(0, max(0, positionMs))
    syncPlayback()
    updatePauseAtEnd()
    emitState()
    updateNowPlaying(seeked = true)
  }

  fun setSpeed(value: Double) {
    Ovoz.checkMainThread()
    if (disposed) return
    speed = max(0.05, value).toFloat()
    applyPlaybackParameters()
    updateNowPlaying(seeked = false)
  }

  fun setVolume(value: Double) {
    Ovoz.checkMainThread()
    if (disposed) return
    volume = value.coerceIn(0.0, 1.0).toFloat()
    applyVolume()
  }

  /**
   * 0: speech, 1: music, 2: none (pitch follows speed). ExoPlayer has one
   * pitch-keeping algorithm (Sonic), so speech and music sound the same.
   */
  fun setPitchCorrection(mode: Int) {
    Ovoz.checkMainThread()
    if (disposed) return
    pitchCorrection = mode
    applyPlaybackParameters()
  }

  // ── Synchronous state (D-07) ─────────────────────────────────────────

  val positionMs: Long
    get() {
      val current = current ?: return 0
      if (current.failed) current.failedAt?.let { return it }
      if (ended) duration()?.let { return it }
      return max(0, exo.currentPosition)
    }

  val bufferedPositionMs: Long
    get() {
      if (current == null) return 0
      val buffered = max(0, exo.bufferedPosition)
      return duration()?.let { min(buffered, it) } ?: buffered
    }

  /** -1 while unknown, and for live streams. */
  val durationMs: Long get() = duration() ?: -1

  /** -1 when nothing is loaded. */
  val currentItemId: Long get() = current?.id ?: -1

  /** A Dart `ProcessingState` index. */
  val processingState: Int get() = state

  val isPlaying: Boolean get() = playWhenReady

  /** Whether the device has a network, as last reported; true until the first report. */
  val isNetworkAvailable: Boolean get() = NetworkMonitor.isAvailable

  // ── Media controls ───────────────────────────────────────────────────

  /**
   * Makes this player the one the notification, lock screen, headsets and
   * cars control (BG-02: at most one player at a time; this takes over from
   * any other). [commands] is a bit set of Dart `MediaCommand` indices.
   */
  fun enableMediaControls(commands: Int, skipForwardMs: Long, skipBackwardMs: Long) {
    Ovoz.checkMainThread()
    if (disposed) return
    MediaControls.claim(this, commands, skipForwardMs, skipBackwardMs)
  }

  /** Takes this player off the notification and lock screen (if it is there). */
  fun disableMediaControls() {
    Ovoz.checkMainThread()
    MediaControls.release(this)
  }

  /**
   * "3 of 12". Android's notification does not show a queue position; kept
   * for the contract.
   */
  @Suppress("UNUSED_PARAMETER")
  fun setQueuePosition(index: Int, count: Int) {
    Ovoz.checkMainThread()
  }

  // ── Lifecycle ────────────────────────────────────────────────────────

  /** Stops playback and releases everything. The player cannot be used again. */
  fun dispose() {
    Ovoz.checkMainThread()
    if (disposed) return
    disposed = true
    MediaControls.release(this)
    playWhenReady = false
    clearWindow()
    exo.removeListener(events)
    exo.removeAnalyticsListener(loads)
    exo.release()
    SessionManager.unregister(this)
    NetworkMonitor.unregister(this)
    Ovoz.unregister(this)
    listener = null
  }

  // ── Used by the engine's managers ────────────────────────────────────

  @get:JvmSynthetic
  internal val wantsPlayback: Boolean get() = playWhenReady && !disposed

  @JvmSynthetic
  internal fun networkChanged(available: Boolean) {
    if (!disposed) listener?.onNetworkChanged(available)
  }

  /**
   * Another app or a call took audio focus: pause. Returns whether this
   * player was playing, so it can be resumed when focus comes back.
   */
  @JvmSynthetic
  internal fun interruptionBegan(): Boolean {
    // Only a player that is to be heard: one at the end of its queue, failed
    // or empty plays nothing, and resuming it would replay or load it.
    val current = current
    if (!playWhenReady || disposed || current == null || current.failed || ended) return false
    playWhenReady = false
    syncPlayback()
    emitState()
    updateNowPlaying(seeked = false)
    return true
  }

  @JvmSynthetic
  internal fun duckingChanged() {
    if (!disposed) applyVolume()
  }

  @JvmSynthetic
  internal fun audioAttributesChanged() {
    if (!disposed) exo.setAudioAttributes(SessionManager.audioAttributes, false)
  }

  @JvmSynthetic
  internal fun remoteCommand(command: Int, value: Double) {
    if (!disposed) listener?.onRemoteCommand(command, value)
  }

  /** What the media session shows for this player; null when nothing is current. */
  @JvmSynthetic
  internal fun nowPlaying(): NowPlaying? {
    val current = current ?: return null
    val item = current.descriptor
    return NowPlaying(
      itemId = current.id,
      title = item.title,
      artist = item.artist,
      album = item.album,
      artworkUri = item.artworkUri,
      durationMs = duration() ?: item.durationHintMs.takeIf { it >= 0 },
      state = state,
      playing = playWhenReady && !ended && !current.failed,
      speed = speed,
    )
  }

  // ── Internals ────────────────────────────────────────────────────────

  private val state: Int
    get() {
      val current = current ?: return ProcessingState.IDLE
      if (current.failed) return ProcessingState.IDLE
      if (ended) return ProcessingState.COMPLETED
      return when (exo.playbackState) {
        Player.STATE_READY -> ProcessingState.READY
        Player.STATE_BUFFERING -> when {
          !current.becameReady -> ProcessingState.LOADING
          // Only a wait while playing is buffering, so a seek while paused
          // never shows a spinner.
          playWhenReady -> ProcessingState.BUFFERING
          else -> ProcessingState.READY
        }
        Player.STATE_ENDED -> ProcessingState.COMPLETED
        // Prepared but not yet started loading.
        else -> ProcessingState.LOADING
      }
    }

  /** The current item's length, clipped; null while unknown and for live streams. */
  private fun duration(): Long? {
    if (current == null || exo.isCurrentMediaItemLive) return null
    val duration = exo.duration
    return if (duration == C.TIME_UNSET) null else duration
  }

  private fun clearWindow() {
    dropNext()
    current?.release()
    current = null
    ended = false
    endReported = null
    lastDuration = null
    // Stopped first: ExoPlayer prepares only from idle, and an error of the
    // old item still on its way from the playback thread would otherwise
    // reach the new one, which would never load.
    exo.stop()
    exo.clearMediaItems()
  }

  private fun attachNext() {
    val cued = next ?: return
    if (nextAttached) return
    exo.addMediaSource(cued.mediaSource)
    nextAttached = true
  }

  private fun dropNext() {
    val cued = next ?: return
    next = null
    if (nextAttached && exo.mediaItemCount > 1) exo.removeMediaItem(1)
    nextAttached = false
    cued.release()
  }

  private fun updatePauseAtEnd() {
    val pause = pauseAtItemEnd && next != null && nextAttached
    if (exo.pauseAtEndOfMediaItems != pause) exo.pauseAtEndOfMediaItems = pause
  }

  /** Puts ExoPlayer's play-when-ready in line with what is wanted. */
  private fun syncPlayback() {
    val current = current
    val play = current != null && !current.failed && !ended && playWhenReady
    if (exo.playWhenReady != play) exo.playWhenReady = play
  }

  private fun applyVolume() {
    exo.volume = if (SessionManager.ducked) volume * DUCKED_VOLUME else volume
  }

  private fun applyPlaybackParameters() {
    val pitch = if (pitchCorrection == PitchCorrection.NONE) speed else 1f
    exo.playbackParameters = PlaybackParameters(speed, pitch)
  }

  /** ExoPlayer moved into the cued item by itself: the current one ended. */
  private fun advanced() {
    val finished = current ?: return
    val upcoming = next ?: return
    if (exo.currentMediaItem?.mediaId != upcoming.mediaId) return
    reportEnd(finished)
    finished.release()
    current = upcoming
    next = null
    nextAttached = false
    ended = false
    upcoming.becameReady = exo.playbackState == Player.STATE_READY
    // The window is the current item and its cue: drop the one just left.
    exo.removeMediaItem(0)
    updatePauseAtEnd()
    listener?.onItemStarted(upcoming.id)
    emitDuration()
    syncPlayback()
    emitState()
    updateNowPlaying(seeked = true)
  }

  /**
   * An item cued after the current one ended: the player moves on into it,
   * as iOS's queue does, playing if playback is still wanted.
   */
  private fun advanceFromEnd() {
    attachNext()
    exo.seekToDefaultPosition(1)
    // The seek reports a transition of its own, which is not an advance.
    advanced()
  }

  /**
   * ExoPlayer paused at the end of the current item (pause at item end with
   * an item cued): the cued item becomes current, paused at its start.
   */
  private fun pausedAtItemEnd() {
    if (current == null || next == null) return
    playWhenReady = false
    exo.seekToDefaultPosition(1)
    // The seek reports a transition of its own, which is not an advance.
    advanced()
  }

  private fun currentFailed(error: PlaybackException) {
    val item = current ?: return
    if (item.failed) return
    val failure = OvozErrors.classify(error, item.remote)
    // Captured first: a load that failed on its way to minute 25 is resumed
    // at minute 25 (ExoPlayer keeps the position it was going to).
    item.failedAt = max(0, exo.currentPosition)
    item.failed = true
    // The error goes first: Dart must hear of the failure while playback was
    // still wanted.
    report(item.id, failure)
    playWhenReady = false
    dropNext()
    updatePauseAtEnd()
    syncPlayback()
    emitState()
    updateNowPlaying(seeked = false)
  }

  /**
   * A cued item that cannot load must not be advanced into; Dart hears about
   * it now and decides what to cue instead. Only failures that retrying will
   * not fix arrive here early; a network failure keeps being retried, and
   * fails the item when it becomes current.
   */
  private fun cuedFailed(item: LoadedItem, error: OvozError) {
    if (item !== next) return
    dropNext()
    updatePauseAtEnd()
    report(item.id, error)
  }

  private fun reportEnd(item: LoadedItem) {
    if (endReported == item.id) return
    endReported = item.id
    listener?.onItemEnded(item.id)
  }

  private fun report(itemId: Long, error: OvozError) {
    listener?.onError(itemId, error.code.ordinal, error.message)
  }

  private fun emitState() {
    if (disposed) return
    val snapshot = state to playWhenReady
    if (snapshot == lastState) return
    lastState = snapshot
    listener?.onStateChanged(snapshot.first, snapshot.second)
    SessionManager.playerStateChanged()
  }

  private fun emitDuration() {
    val current = current ?: return
    val ms = duration() ?: return
    if (lastDuration == (current.id to ms)) return
    lastDuration = current.id to ms
    listener?.onDurationChanged(current.id, ms)
  }

  private fun updateNowPlaying(seeked: Boolean) {
    if (!disposed) MediaControls.update(this, seeked)
  }
}

/** What ExoPlayer's own audio focus handling ducks to. */
private const val DUCKED_VOLUME = 0.2f
