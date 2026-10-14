package uz.sayma.ovoz.engine

import android.app.PendingIntent
import android.content.ComponentName
import android.net.Uri
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import uz.sayma.ovoz.OvozPlaybackService
import uz.sayma.ovoz.OvozPlayer

/** What the media session shows for its owner. */
internal class NowPlaying(
  val itemId: Long,
  val title: String?,
  val artist: String?,
  val album: String?,
  val artworkUri: String?,
  val durationMs: Long?,
  /** A Dart `ProcessingState` index. */
  val state: Int,
  /** Whether playback is wanted and possible (not ended, not failed). */
  val playing: Boolean,
  val speed: Float,
)

/**
 * The process-wide media session, its notification and the system's media
 * controls, owned by at most one player at a time (D-15, BG-02).
 *
 * The session wraps a stand-in player ([SessionPlayer]) that shows the
 * owner's item and state and forwards every command to the owner's Dart
 * listener instead of acting on it, so the app's rules (a hold, an
 * advertisement) apply to a headset button exactly as to a button in the app
 * — the same model as `NowPlayingCenter` on iOS.
 *
 * Playing in the background needs a foreground service: the app declares
 * [OvozPlaybackService] (D-16), which Media3 starts and stops as playback
 * starts and stops, with the notification. While a player owns the controls
 * this keeps a controller connected to the service, which creates it.
 */
@UnstableApi
internal object MediaControls {
  var owner: OvozPlayer? = null
    private set

  private var commands = 0
  private var skipForwardMs = 15_000L
  private var skipBackwardMs = 15_000L

  private var player: SessionPlayer? = null
  var session: MediaSession? = null
    private set

  private var service: OvozPlaybackService? = null
  private var controller: ListenableFuture<MediaController>? = null
  private var warnedNoService = false

  fun claim(player: OvozPlayer, commands: Int, skipForwardMs: Long, skipBackwardMs: Long) {
    val changedOwner = owner !== player
    owner = player
    this.commands = commands
    this.skipForwardMs = skipForwardMs
    this.skipBackwardMs = skipBackwardMs
    val session = ensureSession()
    session.setMediaButtonPreferences(buttons())
    this.player?.refresh(seeked = changedOwner)
    connectService()
  }

  fun release(player: OvozPlayer) {
    if (owner !== player) return
    owner = null
    this.player?.refresh(seeked = true)
    disconnectService()
    // Media3 leaves a started service running until the app stops it. Once
    // the session has seen the owner go (and no other player claimed the
    // controls meanwhile), nothing is left for it to do.
    Ovoz.mainHandler.post {
      if (owner == null) service?.pauseAllPlayersAndStopSelf()
    }
  }

  /** Republishes [player]'s item and state, if it is the owner. */
  fun update(player: OvozPlayer, seeked: Boolean) {
    if (owner === player) this.player?.refresh(seeked)
  }

  /** The last Flutter engine went away. */
  fun shutDown() {
    owner = null
    disconnectService()
    service?.pauseAllPlayersAndStopSelf()
    session?.release()
    session = null
    player?.release()
    player = null
  }

  // ── The service ──────────────────────────────────────────────────────

  fun serviceCreated(service: OvozPlaybackService): MediaSession? {
    this.service = service
    return session
  }

  fun serviceDestroyed(service: OvozPlaybackService) {
    if (this.service === service) this.service = null
  }

  private fun connectService() {
    if (controller != null) return
    val context = Ovoz.context
    if (!OvozPlaybackService.isDeclared(context)) {
      if (!warnedNoService) {
        warnedNoService = true
        Ovoz.warn(
          "ovoz: OvozPlaybackService is not declared in AndroidManifest.xml: no media notification, " +
            "and playback stops when the app goes to the background (see the README)",
        )
      }
      return
    }
    val token = SessionToken(context, ComponentName(context, OvozPlaybackService::class.java))
    val future = MediaController.Builder(context, token).buildAsync()
    controller = future
    future.addListener({
      try {
        future.get()
      } catch (e: Exception) {
        Ovoz.warn("ovoz: could not start OvozPlaybackService: $e")
        if (controller === future) controller = null
      }
    }, ContextCompat.getMainExecutor(context))
  }

  private fun disconnectService() {
    controller?.let { MediaController.releaseFuture(it) }
    controller = null
  }

  private fun ensureSession(): MediaSession {
    session?.let { return it }
    val context = Ovoz.context
    val stand = SessionPlayer().also { player = it }
    val builder = MediaSession.Builder(context, stand).setId("ovoz")
    context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
      // Tapping the notification opens the app.
      builder.setSessionActivity(
        PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
      )
    }
    val made = builder.build()
    session = made
    service?.addSession(made)
    return made
  }

  // ── Commands ─────────────────────────────────────────────────────────

  private fun enabled(command: Int) = commands and (1 shl command) != 0

  fun availableCommands(): Player.Commands {
    val builder = Player.Commands.Builder().addAll(
      Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
      Player.COMMAND_GET_TIMELINE,
      Player.COMMAND_GET_METADATA,
    )
    if (enabled(RemoteCommand.PLAY) || enabled(RemoteCommand.PAUSE) || enabled(RemoteCommand.TOGGLE_PLAY_PAUSE)) {
      builder.add(Player.COMMAND_PLAY_PAUSE)
    }
    if (enabled(RemoteCommand.STOP)) builder.add(Player.COMMAND_STOP)
    if (enabled(RemoteCommand.NEXT)) builder.addAll(Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
    if (enabled(RemoteCommand.PREVIOUS)) {
      builder.addAll(Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
    }
    if (enabled(RemoteCommand.SEEK)) builder.add(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
    if (enabled(RemoteCommand.SKIP_FORWARD)) builder.add(Player.COMMAND_SEEK_FORWARD)
    if (enabled(RemoteCommand.SKIP_BACKWARD)) builder.add(Player.COMMAND_SEEK_BACK)
    if (enabled(RemoteCommand.CHANGE_RATE)) builder.add(Player.COMMAND_SET_SPEED_AND_PITCH)
    return builder.build()
  }

  /**
   * Skip buttons take the back and forward places in the notification, as
   * they take next and previous on the iOS lock screen when both are enabled.
   */
  private fun buttons(): List<CommandButton> {
    val buttons = mutableListOf<CommandButton>()
    if (enabled(RemoteCommand.SKIP_BACKWARD)) {
      buttons += CommandButton.Builder(skipBackIcon(skipBackwardMs))
        .setPlayerCommand(Player.COMMAND_SEEK_BACK)
        .setDisplayName("Back ${skipBackwardMs / 1000} s")
        .build()
    }
    if (enabled(RemoteCommand.SKIP_FORWARD)) {
      buttons += CommandButton.Builder(skipForwardIcon(skipForwardMs))
        .setPlayerCommand(Player.COMMAND_SEEK_FORWARD)
        .setDisplayName("Forward ${skipForwardMs / 1000} s")
        .build()
    }
    return buttons
  }

  private fun skipBackIcon(ms: Long) = when (ms) {
    5_000L -> CommandButton.ICON_SKIP_BACK_5
    10_000L -> CommandButton.ICON_SKIP_BACK_10
    15_000L -> CommandButton.ICON_SKIP_BACK_15
    30_000L -> CommandButton.ICON_SKIP_BACK_30
    else -> CommandButton.ICON_SKIP_BACK
  }

  private fun skipForwardIcon(ms: Long) = when (ms) {
    5_000L -> CommandButton.ICON_SKIP_FORWARD_5
    10_000L -> CommandButton.ICON_SKIP_FORWARD_10
    15_000L -> CommandButton.ICON_SKIP_FORWARD_15
    30_000L -> CommandButton.ICON_SKIP_FORWARD_30
    else -> CommandButton.ICON_SKIP_FORWARD
  }

  /**
   * The player the media session sees: the owner's item and state, read
   * fresh whenever the session asks, and commands that go to the owner's
   * Dart listener. It plays nothing itself.
   */
  private class SessionPlayer : SimpleBasePlayer(Looper.getMainLooper()) {
    private var seeked = false

    /**
     * Commands forwarded and not yet applied. The session shows its own guess
     * until the owner's state changes, or a second passes (the app's own
     * handler may have kept the command).
     */
    private val pending = mutableListOf<SettableFuture<Any?>>()

    fun refresh(seeked: Boolean) {
      if (seeked) this.seeked = true
      settlePending()
      invalidateState()
    }

    private fun settlePending() {
      val settled = pending.toList()
      pending.clear()
      settled.forEach { it.set(null) }
    }

    override fun getState(): State {
      val owner = owner
      val now = owner?.nowPlaying()
      val builder = State.Builder()
        .setAvailableCommands(availableCommands())
        .setSeekBackIncrementMs(skipBackwardMs)
        .setSeekForwardIncrementMs(skipForwardMs)
      if (owner == null || now == null) {
        seeked = false
        return builder
          .setPlaylist(emptyList())
          .setPlaybackState(Player.STATE_IDLE)
          .setPlayWhenReady(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
          .build()
      }
      val metadata = MediaMetadata.Builder()
        .setTitle(now.title.orEmpty())
        .setArtist(now.artist)
        .setAlbumTitle(now.album)
        .setArtworkUri(now.artworkUri?.let(::artworkUri))
        .setDurationMs(now.durationMs)
        .build()
      val item = MediaItemData.Builder("ovoz-${now.itemId}")
        .setMediaItem(MediaItem.Builder().setMediaId(now.itemId.toString()).setMediaMetadata(metadata).build())
        .setDurationUs(now.durationMs?.let { it * 1000 } ?: C.TIME_UNSET)
        .setIsSeekable(now.durationMs != null)
        .build()
      val playbackState = when (now.state) {
        ProcessingState.LOADING, ProcessingState.BUFFERING -> Player.STATE_BUFFERING
        ProcessingState.COMPLETED -> Player.STATE_ENDED
        // Ready, and failed or given up on: the item stays, paused, so it
        // can be played again from here.
        else -> Player.STATE_READY
      }
      builder
        .setPlaylist(listOf(item))
        .setCurrentMediaItemIndex(0)
        .setPlaybackState(playbackState)
        .setPlayWhenReady(now.playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        .setIsLoading(playbackState == Player.STATE_BUFFERING)
        .setContentPositionMs { owner.positionMs }
        .setContentBufferedPositionMs { owner.bufferedPositionMs }
        .setPlaybackParameters(PlaybackParameters(now.speed))
        .setAudioAttributes(SessionManager.audioAttributes)
      if (seeked) {
        seeked = false
        builder.setPositionDiscontinuity(Player.DISCONTINUITY_REASON_SEEK, owner.positionMs)
      }
      return builder.build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> =
      forward(if (playWhenReady) RemoteCommand.PLAY else RemoteCommand.PAUSE)

    override fun handleStop(): ListenableFuture<*> = forward(RemoteCommand.STOP)

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> =
      when (seekCommand) {
        Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> forward(RemoteCommand.NEXT)
        Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> forward(RemoteCommand.PREVIOUS)
        Player.COMMAND_SEEK_FORWARD -> forward(RemoteCommand.SKIP_FORWARD, skipForwardMs.toDouble())
        Player.COMMAND_SEEK_BACK -> forward(RemoteCommand.SKIP_BACKWARD, skipBackwardMs.toDouble())
        else -> forward(RemoteCommand.SEEK, if (positionMs == C.TIME_UNSET) 0.0 else positionMs.coerceAtLeast(0).toDouble())
      }

    override fun handleSetPlaybackParameters(playbackParameters: PlaybackParameters): ListenableFuture<*> =
      forward(RemoteCommand.CHANGE_RATE, playbackParameters.speed.toDouble())

    override fun handleRelease(): ListenableFuture<*> = Futures.immediateVoidFuture()

    private fun forward(command: Int, value: Double = 0.0): ListenableFuture<*> {
      val owner = owner ?: return Futures.immediateVoidFuture()
      val future = SettableFuture.create<Any?>()
      pending += future
      Ovoz.mainHandler.postDelayed({
        if (pending.remove(future)) future.set(null)
      }, 1_000)
      owner.remoteCommand(command, value)
      return future
    }

    /** Flutter assets are read from the APK's `flutter_assets/`. */
    private fun artworkUri(uri: String): Uri {
      val parsed = uri.toUri()
      if (parsed.scheme != "asset") return parsed
      val path = Ovoz.assetPath(parsed.path.orEmpty().trimStart('/')) ?: return parsed
      return "asset:///$path".toUri()
    }
  }
}
