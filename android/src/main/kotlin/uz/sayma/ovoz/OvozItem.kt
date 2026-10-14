package uz.sayma.ovoz

import androidx.annotation.Keep
import uz.sayma.ovoz.loader.EncryptionLayout
import uz.sayma.ovoz.loader.SecureBytes

/**
 * What Dart asks a player to play: a cheap descriptor, turned into a media
 * source only when it enters the player's window (D-04, PL-07).
 *
 * [itemId] is chosen by Dart and is new every time an item is handed over,
 * even for the same source, so events always say which instance they are
 * about (a looped item is a new instance each lap).
 */
@Keep
class OvozItem(
  val itemId: Long,
  /** `file:///…`, `asset:///<flutter asset key>`, `http(s)://…`. */
  val uri: String,
) {
  /** Declared container format (`mp3`, `m4a`, …). Required for encrypted sources. */
  var format: String? = null

  /** Clip bounds in milliseconds; `clipEndMs < 0` plays to the end. */
  var clipStartMs: Long = 0
  var clipEndMs: Long = -1

  // What the notification and the lock screen show.
  var title: String? = null
  var artist: String? = null
  var album: String? = null
  var artworkUri: String? = null

  /** Length to show before the player has measured it; < 0 when unknown. */
  var durationHintMs: Long = -1

  private val headerFields = LinkedHashMap<String, String>()
  private var layout: EncryptionLayout? = null

  @get:JvmSynthetic
  internal val headers: Map<String, String> get() = headerFields

  @get:JvmSynthetic
  internal val encryption: EncryptionLayout? get() = layout

  /** Sent with every HTTP request for this item. */
  fun addHeader(name: String, value: String) {
    headerFields[name] = value
  }

  /**
   * Decrypts the source with AES-CTR. With [ivInHeader] the IV is read from
   * the first 16 bytes of the file and [iv] is ignored. [dataOffset] is where
   * the ciphertext starts.
   *
   * The key is copied into memory the engine owns (ENC-06), and [key], which
   * the caller made for this call only, is zeroed.
   */
  fun setAesCtr(key: ByteArray, iv: ByteArray, ivInHeader: Boolean, dataOffset: Long) {
    layout = EncryptionLayout(SecureBytes(key), if (ivInHeader) null else iv.copyOf(), dataOffset)
    key.fill(0)
  }

  override fun toString(): String = "OvozItem($itemId, $uri)"
}
