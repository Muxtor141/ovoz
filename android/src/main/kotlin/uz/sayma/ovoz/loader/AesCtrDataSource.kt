package uz.sayma.ovoz.loader

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener
import java.io.EOFException
import kotlin.math.min
import uz.sayma.ovoz.engine.OvozErrorCode
import uz.sayma.ovoz.engine.OvozIOException

/** How an encrypted resource is laid out (ENC-03). */
internal class EncryptionLayout(
  val key: SecureBytes,
  /** The IV, or null when it is stored in the file's first 16 bytes. */
  val iv: ByteArray?,
  /**
   * Where the ciphertext starts: 0 for a bare file, 16 when the IV is the
   * file's header, or wherever the app's own header ends.
   */
  val dataOffset: Long,
)

/**
 * One encrypted item, shared by every data source ExoPlayer opens for it (it
 * opens one per load: the first, after each seek, after each retry).
 *
 * Prepares once: the total length, the IV (given or from the header) and the
 * signature check that tells a wrong key at once (ENC-07). A failure the
 * engine diagnosed is kept, so the item fails the same way however often it
 * is opened; a network failure is not, so a retry can still succeed.
 */
@UnstableApi
internal class EncryptedResource(
  val layout: EncryptionLayout,
  val format: AudioFormatInfo,
  /** Read over HTTP: every request is a byte range, answered with 206. */
  private val remote: Boolean,
) {
  class Prepared(
    /** C.LENGTH_UNSET when the source does not say (a compressed asset). */
    val plaintextLength: Long,
    val iv: ByteArray,
  )

  private var prepared: Prepared? = null
  private var failure: OvozIOException? = null

  @Synchronized
  fun prepare(upstream: DataSource, spec: DataSpec): Prepared {
    prepared?.let { return it }
    failure?.let { throw it }
    try {
      return load(upstream, spec).also { prepared = it }
    } catch (e: OvozIOException) {
      failure = e
      throw e
    }
  }

  private fun load(upstream: DataSource, spec: DataSpec): Prepared {
    val headerLength = layout.dataOffset + AudioFormatInfo.SIGNATURE_LENGTH
    // Remote: a small range, whose Content-Range gives the total length.
    // Local: the whole file, whose open gives it.
    val probe = spec.buildUpon().setPosition(0).setLength(if (remote) headerLength else C.LENGTH_UNSET.toLong()).build()
    val total: Long
    val header: ByteArray
    try {
      val opened = upstream.open(probe)
      total = if (remote) checkRange(upstream, start = 0).total else opened
      header = readUpTo(upstream, headerLength.toInt())
    } finally {
      upstream.close()
    }
    if (total != C.LENGTH_UNSET.toLong() && total < layout.dataOffset) {
      throw OvozIOException(OvozErrorCode.DECRYPTION, "The file is shorter than its ${layout.dataOffset}-byte header")
    }
    val iv = layout.iv ?: if (header.size >= AesCtrCipher.BLOCK_SIZE) {
      header.copyOf(AesCtrCipher.BLOCK_SIZE)
    } else {
      throw OvozIOException(OvozErrorCode.DECRYPTION, "The file is too short to hold its IV")
    }
    val body = if (header.size > layout.dataOffset) header.copyOfRange(layout.dataOffset.toInt(), header.size) else ByteArray(0)
    if (body.isNotEmpty()) {
      AesCtrCipher(layout.key, iv).apply { apply(body, 0, body.size, 0) }.release()
      if (!format.matches(body)) {
        val ivHint = if (layout.iv == null) "" else " or IV"
        throw OvozIOException(
          OvozErrorCode.DECRYPTION,
          "Decrypted bytes do not start like a $format file: wrong key$ivHint, or the format is not $format",
        )
      }
    }
    val plaintextLength = if (total == C.LENGTH_UNSET.toLong()) total else total - layout.dataOffset
    return Prepared(plaintextLength, iv)
  }

  class Range(val start: Long, val total: Long)

  /**
   * What a remote answer to a range starting at [start] must be for
   * decryption to line up: 206, uncompressed, starting where asked. Anything
   * else is `rangeNotSupported`, as on iOS.
   */
  fun checkRange(upstream: DataSource, start: Long): Range {
    val http = upstream as? HttpDataSource ?: return Range(start, C.LENGTH_UNSET.toLong())
    val uri = http.uri ?: "the server"
    val code = http.responseCode
    if (code != 206) {
      throw OvozIOException(OvozErrorCode.RANGE_NOT_SUPPORTED, "$uri ignored the Range header ($code instead of 206)")
    }
    val headers = http.responseHeaders
    val encoding = header(headers, "Content-Encoding")
    if (encoding != null && !encoding.equals("identity", ignoreCase = true)) {
      throw OvozIOException(OvozErrorCode.RANGE_NOT_SUPPORTED, "$uri compressed the body ($encoding); byte offsets would not match")
    }
    // Content-Range: bytes 0-1023/146515
    val range = header(headers, "Content-Range")
    val match = range?.let { CONTENT_RANGE.find(it) }
      ?: throw OvozIOException(OvozErrorCode.RANGE_NOT_SUPPORTED, "$uri sent no usable Content-Range")
    val first = match.groupValues[1].toLong()
    if (first != start) {
      throw OvozIOException(OvozErrorCode.RANGE_NOT_SUPPORTED, "$uri answered a different range: $range")
    }
    return Range(first, match.groupValues[3].toLong())
  }

  companion object {
    private val CONTENT_RANGE = Regex("""bytes\s+(\d+)-(\d+)/(\d+)""", RegexOption.IGNORE_CASE)

    private fun header(headers: Map<String, List<String>>, name: String): String? =
      headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.firstOrNull()

    private fun readUpTo(source: DataSource, length: Int): ByteArray {
      val buffer = ByteArray(length)
      var filled = 0
      while (filled < length) {
        val read = source.read(buffer, filled, length - filled)
        if (read == C.RESULT_END_OF_INPUT) break
        filled += read
      }
      return if (filled == length) buffer else buffer.copyOf(filled)
    }
  }
}

/**
 * Plays an encrypted resource by decrypting it in memory, inside ExoPlayer's
 * loading pipeline (D-06): ExoPlayer asks for plaintext byte ranges, this
 * source reads the matching ciphertext from [upstream] (a file, an asset or
 * HTTP) and decrypts it on the way through. No local proxy, no decrypted copy
 * on disk.
 *
 * Runs on ExoPlayer's loading threads. One instance serves one load at a
 * time, as ExoPlayer requires.
 */
@UnstableApi
internal class AesCtrDataSource(
  private val upstream: DataSource,
  private val resource: EncryptedResource,
) : DataSource {
  private var cipher: AesCtrCipher? = null

  /** Plaintext offset of the next byte read. */
  private var position = 0L

  /** Plaintext bytes left in this open; C.LENGTH_UNSET when unknown. */
  private var remaining = 0L

  override fun addTransferListener(transferListener: TransferListener) {
    upstream.addTransferListener(transferListener)
  }

  override fun open(dataSpec: DataSpec): Long {
    val prepared = resource.prepare(upstream, dataSpec)
    val length = prepared.plaintextLength
    val start = dataSpec.position
    val unset = C.LENGTH_UNSET.toLong()
    if (length != unset && start > length) {
      throw DataSourceException(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
    }
    val available = if (length == unset) unset else length - start
    val requested = if (dataSpec.length == unset) available else dataSpec.length
    val bounded = if (requested == unset || available == unset) requested else min(requested, available)
    // Always a closed range for HTTP, so the server must answer with 206.
    val upstreamSpec = dataSpec.buildUpon()
      .setPosition(resource.layout.dataOffset + start)
      .setLength(bounded)
      .build()
    position = start
    remaining = bounded
    if (bounded == 0L) return 0
    upstream.open(upstreamSpec)
    resource.checkRange(upstream, upstreamSpec.position)
    cipher = AesCtrCipher(resource.layout.key, prepared.iv)
    return requested
  }

  override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
    if (length == 0) return 0
    if (remaining == 0L) return C.RESULT_END_OF_INPUT
    val want = if (remaining == C.LENGTH_UNSET.toLong()) length else min(length.toLong(), remaining).toInt()
    val read = upstream.read(buffer, offset, want)
    if (read == C.RESULT_END_OF_INPUT) {
      if (remaining == C.LENGTH_UNSET.toLong()) return read
      // Shorter than it was when prepared: deleted, truncated or cut off.
      val message = "${upstream.uri} ended early at byte ${resource.layout.dataOffset + position}"
      if (upstream is HttpDataSource) throw EOFException(message)
      throw OvozIOException(OvozErrorCode.SOURCE_NOT_FOUND, message)
    }
    checkNotNull(cipher).apply(buffer, offset, read, position)
    position += read
    if (remaining != C.LENGTH_UNSET.toLong()) remaining -= read
    return read
  }

  override fun getUri(): Uri? = upstream.uri

  override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

  /** Called after every open, including one that threw. */
  override fun close() {
    cipher?.release()
    cipher = null
    remaining = 0
    upstream.close()
  }

  class Factory(
    private val upstream: DataSource.Factory,
    private val resource: EncryptedResource,
  ) : DataSource.Factory {
    override fun createDataSource(): DataSource = AesCtrDataSource(upstream.createDataSource(), resource)
  }
}
