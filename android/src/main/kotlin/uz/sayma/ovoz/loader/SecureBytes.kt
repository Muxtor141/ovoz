package uz.sayma.ovoz.loader

import java.io.IOException

/**
 * Key material the engine owns: copied in once, never logged, and zeroed when
 * released (ENC-06).
 *
 * Each cipher made from it holds its own copy inside the platform's crypto
 * provider, freed with the cipher; this is the copy that lives as long as the
 * item does.
 */
internal class SecureBytes(source: ByteArray) {
  private val bytes = source.copyOf()

  @Volatile private var released = false

  val size: Int get() = bytes.size

  /**
   * Runs [block] with the bytes. Throws once released: a load still running
   * for an item that has left the player fails instead of using a zeroed key.
   */
  @Synchronized
  fun <R> use(block: (ByteArray) -> R): R {
    if (released) throw IOException("The item was released")
    return block(bytes)
  }

  @Synchronized
  fun release() {
    released = true
    bytes.fill(0)
  }

  /** Never prints the bytes. */
  override fun toString(): String = "SecureBytes($size bytes)"
}
