package uz.sayma.ovoz.engine

import android.net.Uri
import androidx.core.net.toUri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.extractor.DefaultExtractorsFactory
import java.io.File
import java.io.IOException
import kotlin.math.max
import kotlin.math.min
import uz.sayma.ovoz.OvozItem
import uz.sayma.ovoz.loader.AesCtrDataSource
import uz.sayma.ovoz.loader.AudioFormatInfo
import uz.sayma.ovoz.loader.EncryptedResource
import uz.sayma.ovoz.loader.EncryptionLayout

/**
 * An [OvozItem] made playable: the media source ExoPlayer plays, built only
 * when the item enters the player's window (D-04, PL-07), and the state the
 * player keeps about it.
 */
@UnstableApi
internal class LoadedItem private constructor(
  val descriptor: OvozItem,
  val mediaSource: MediaSource,
  /** Streamed over HTTP: an unspecified I/O failure is then a network one. */
  val remote: Boolean,
  private val encryption: EncryptionLayout?,
) {
  val id: Long get() = descriptor.itemId

  /** The id of its `MediaItem`, which load events carry. */
  val mediaId: String get() = id.toString()

  /** Ready to play at least once. Until then, waiting for data is loading, not buffering. */
  var becameReady = false

  /** Set when the item failed; it stays current so the state is clear. */
  var failed = false

  /**
   * Where the item was when it failed: its start position if it never got
   * there. A failed item reports this as its position, so that it is resumed
   * from there, not from zero.
   */
  var failedAt: Long? = null

  /** Zeroes the key (ENC-06). Loads still running for the item then fail. */
  fun release() {
    encryption?.key?.release()
  }

  sealed interface Made

  class Built(val item: LoadedItem) : Made

  class Failed(val error: OvozError) : Made

  companion object {
    /**
     * Seeking by bitrate in MP3 and ADTS files without a seek table, which
     * would otherwise not seek at all.
     */
    private val extractors = DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true)

    /**
     * Builds the item, or explains why it cannot be built. A missing local
     * file or asset fails here, at once, rather than as an error from
     * ExoPlayer later.
     */
    fun make(descriptor: OvozItem): Made {
      val uri = descriptor.uri.toUri()
      val location: Uri
      val remote: Boolean
      when (uri.scheme?.lowercase()) {
        "file" -> {
          val path = uri.path
          if (path == null || !File(path).isFile) return failed(OvozErrorCode.SOURCE_NOT_FOUND, "No file at $path")
          location = uri
          remote = false
        }
        "asset" -> {
          val key = uri.path.orEmpty().trimStart('/')
          val path = Ovoz.assetPath(key) ?: return failed(OvozErrorCode.SOURCE_NOT_FOUND, "No Flutter asset $key")
          location = "asset:///$path".toUri()
          remote = false
        }
        "http", "https" -> {
          if (uri.host.isNullOrEmpty()) return failed(OvozErrorCode.INVALID_CONFIGURATION, "Not a URL: ${descriptor.uri}")
          location = uri
          remote = true
        }
        null -> return failed(OvozErrorCode.INVALID_CONFIGURATION, "Not a URI: ${descriptor.uri}")
        else -> return failed(OvozErrorCode.INVALID_CONFIGURATION, "Unsupported scheme in ${descriptor.uri}")
      }

      val upstream: DataSource.Factory = if (remote) {
        // Headers go with every request: progressive ranges, and for HLS
        // the playlists, keys and segments.
        DefaultHttpDataSource.Factory()
          .setDefaultRequestProperties(descriptor.headers)
          .setAllowCrossProtocolRedirects(true)
      } else {
        DefaultDataSource.Factory(Ovoz.context)
      }

      val layout = descriptor.encryption
      val factory: DataSource.Factory
      if (layout != null) {
        val format = descriptor.format?.let(AudioFormatInfo::named)
          ?: return failed(
            OvozErrorCode.INVALID_CONFIGURATION,
            "Encrypted sources must declare a supported format (mp3, aac, m4a, wav, flac); got ${descriptor.format ?: "none"}",
          )
        if (!format.playableOnAndroid) {
          return failed(OvozErrorCode.UNSUPPORTED_FORMAT, "Android cannot play $format files")
        }
        if (Util.inferContentType(location) == C.CONTENT_TYPE_HLS) {
          return failed(OvozErrorCode.INVALID_CONFIGURATION, "HLS cannot be encrypted with AES-CTR; use HLS's own encryption")
        }
        factory = AesCtrDataSource.Factory(upstream, EncryptedResource(layout, format, remote))
      } else {
        factory = upstream
      }

      val mediaItem = MediaItem.Builder()
        .setUri(location)
        .setMediaId(descriptor.itemId.toString())
        .apply {
          if (descriptor.clipStartMs > 0 || descriptor.clipEndMs >= 0) {
            val clip = MediaItem.ClippingConfiguration.Builder().setStartPositionMs(max(0, descriptor.clipStartMs))
            if (descriptor.clipEndMs >= 0) clip.setEndPositionMs(max(descriptor.clipEndMs, descriptor.clipStartMs))
            setClippingConfiguration(clip.build())
          }
        }
        .build()
      val source = DefaultMediaSourceFactory(factory, extractors)
        .setLoadErrorHandlingPolicy(OvozLoadErrorPolicy)
        .createMediaSource(mediaItem)
      return Built(LoadedItem(descriptor, source, remote, layout))
    }

    private fun failed(code: OvozErrorCode, message: String) = Failed(OvozError(code, message))
  }
}

/**
 * Retries a failed load twice, after 0.5 and 1 s, as the iOS engine's HTTP
 * source does; a load that makes progress starts counting again. What will not
 * get better by retrying fails at once: the engine's own diagnosis (a wrong
 * key, a server that ignores ranges) and a refused request.
 */
@UnstableApi
internal object OvozLoadErrorPolicy : DefaultLoadErrorHandlingPolicy(2) {
  override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
    if (isDefinitive(loadErrorInfo.exception)) return C.TIME_UNSET
    if (super.getRetryDelayMsFor(loadErrorInfo) == C.TIME_UNSET) return C.TIME_UNSET
    return min(500L * loadErrorInfo.errorCount, 2_000L)
  }

  /** Whether a load that failed with [error] is never retried. */
  fun isFatal(loadEventInfo: LoadEventInfo, mediaLoadData: MediaLoadData, error: IOException): Boolean =
    getRetryDelayMsFor(LoadErrorHandlingPolicy.LoadErrorInfo(loadEventInfo, mediaLoadData, error, 1)) == C.TIME_UNSET

  private fun isDefinitive(error: Throwable): Boolean {
    var cause: Throwable? = error
    var depth = 0
    while (cause != null && depth < 10) {
      if (cause is OvozIOException) return true
      // 408 and 429 ask to try again later; any other 4xx will not change.
      if (cause is HttpDataSource.InvalidResponseCodeException) {
        return cause.responseCode in 400..499 && cause.responseCode != 408 && cause.responseCode != 429
      }
      cause = cause.cause
      depth++
    }
    return false
  }
}
