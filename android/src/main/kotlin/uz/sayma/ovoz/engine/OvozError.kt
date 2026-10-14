package uz.sayma.ovoz.engine

import androidx.media3.common.ParserException
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.HttpDataSource
import java.io.FileNotFoundException
import java.io.IOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * What went wrong, in categories an app can act on. The values are part of
 * the Dart contract (`AudioErrorKind`).
 */
internal enum class OvozErrorCode {
  UNKNOWN,
  SOURCE_NOT_FOUND,
  NETWORK,
  DECRYPTION,
  UNSUPPORTED_FORMAT,
  RANGE_NOT_SUPPORTED,
  INVALID_CONFIGURATION,
}

internal data class OvozError(val code: OvozErrorCode, val message: String)

/**
 * A failure the engine diagnosed itself (a wrong key, a server that ignores
 * ranges), more precise than what ExoPlayer would report. An [IOException], so
 * it travels through ExoPlayer's loading pipeline as the cause of the
 * playback error, and is never retried.
 */
internal class OvozIOException(val code: OvozErrorCode, message: String) : IOException(message) {
  val error: OvozError get() = OvozError(code, message ?: code.name)
}

@UnstableApi
internal object OvozErrors {
  /**
   * Classifies a playback error, walking its cause chain: ExoPlayer wraps the
   * cause it got from the network, the file system or the engine's own
   * decrypting source. [remote] says whether the item was streamed, which
   * decides what an unspecified I/O failure most likely was.
   */
  fun classify(error: Throwable?, remote: Boolean): OvozError {
    if (error == null) return OvozError(OvozErrorCode.UNKNOWN, "Playback failed for an unknown reason")
    val message = describe(error)
    var cause: Throwable? = error
    var depth = 0
    while (cause != null && depth < 10) {
      val link = cause
      // The engine's own diagnosis wins, with its own message.
      if (link is OvozIOException) return link.error
      classifyCause(link)?.let { return OvozError(it, message) }
      // A data source's own reason, for errors that reach us unwrapped (a cued
      // item's load error).
      if (link is DataSourceException) {
        codeFor(link.reason, remote).takeIf { it != OvozErrorCode.UNKNOWN }?.let { return OvozError(it, message) }
      }
      cause = link.cause
      depth++
    }
    val code = codeFor((error as? PlaybackException)?.errorCode, remote)
    return OvozError(code, message)
  }

  /** What a Media3 error code (a playback error's, or a data source's reason) means. */
  private fun codeFor(errorCode: Int?, remote: Boolean): OvozErrorCode =
    when (errorCode) {
      PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
      PlaybackException.ERROR_CODE_IO_NO_PERMISSION,
      -> OvozErrorCode.SOURCE_NOT_FOUND
      PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
      PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
      PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
      PlaybackException.ERROR_CODE_TIMEOUT,
      -> OvozErrorCode.NETWORK
      PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED -> OvozErrorCode.INVALID_CONFIGURATION
      PlaybackException.ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE,
      PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
      PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
      PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
      PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
      PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
      PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
      PlaybackException.ERROR_CODE_DECODING_FAILED,
      PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
      PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
      -> OvozErrorCode.UNSUPPORTED_FORMAT
      PlaybackException.ERROR_CODE_IO_UNSPECIFIED -> if (remote) OvozErrorCode.NETWORK else OvozErrorCode.UNKNOWN
      else -> OvozErrorCode.UNKNOWN
    }

  private fun classifyCause(cause: Throwable): OvozErrorCode? = when (cause) {
    is HttpDataSource.InvalidResponseCodeException ->
      if (cause.responseCode in REFUSED) OvozErrorCode.SOURCE_NOT_FOUND else OvozErrorCode.NETWORK
    is HttpDataSource.CleartextNotPermittedException -> OvozErrorCode.INVALID_CONFIGURATION
    is FileNotFoundException -> OvozErrorCode.SOURCE_NOT_FOUND
    // Not audio, or audio the platform cannot read.
    is ParserException -> OvozErrorCode.UNSUPPORTED_FORMAT
    // Refused, unreachable, reset or timed out.
    is UnknownHostException, is SocketException, is SocketTimeoutException -> OvozErrorCode.NETWORK
    else -> null
  }

  /** HTTP answers that mean the resource is not there for this client, now or later. */
  val REFUSED = setOf(401, 403, 404, 410)

  private fun describe(error: Throwable): String {
    val parts = mutableListOf<String>()
    if (error is PlaybackException) parts += error.errorCodeName
    error.message?.let { parts += it }
    var cause = error.cause
    var depth = 0
    while (cause != null && depth < 4) {
      parts += "(${cause.javaClass.simpleName}: ${cause.message ?: "no message"})"
      cause = cause.cause
      depth++
    }
    return parts.joinToString(" ")
  }
}
