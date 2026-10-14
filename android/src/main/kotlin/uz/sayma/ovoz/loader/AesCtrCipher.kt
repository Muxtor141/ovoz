package uz.sayma.ovoz.loader

import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import uz.sayma.ovoz.engine.OvozErrorCode
import uz.sayma.ovoz.engine.OvozIOException

/**
 * AES in CTR mode, decrypting from any byte offset (ENC-01, ENC-04).
 *
 * The 16-byte IV is the first counter block, and the counter is the whole
 * block read as one 128-bit big-endian integer (ENC-02). That is what
 * PointyCastle (Dart's `encrypt` package) and OpenSSL do, and what Mutolaa's
 * files were written with.
 *
 * The keystream is built here, counter blocks encrypted with AES-ECB, rather
 * than by the provider's CTR mode, so the counter arithmetic is ours and
 * cannot differ from the encryptor's (the same choice as on iOS).
 *
 * Not thread-safe: each open data source uses its own instance.
 */
// ECB of counter blocks is how CTR's keystream is made, not ECB used to
// encrypt data.
@Suppress("GetInstance")
internal class AesCtrCipher(key: SecureBytes, iv: ByteArray) {
  private val cipher: Cipher
  private val ivHigh: Long
  private val ivLow: Long

  /** Reused between calls so steady-state decryption allocates nothing. */
  private var counters = ByteArray(0)
  private var keystream = ByteArray(0)

  init {
    if (key.size != 16 && key.size != 24 && key.size != 32) {
      throw OvozIOException(OvozErrorCode.INVALID_CONFIGURATION, "AES key must be 16, 24 or 32 bytes, got ${key.size}")
    }
    if (iv.size != BLOCK_SIZE) {
      throw OvozIOException(OvozErrorCode.INVALID_CONFIGURATION, "AES-CTR IV must be 16 bytes, got ${iv.size}")
    }
    cipher = Cipher.getInstance("AES/ECB/NoPadding")
    key.use { cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(it, "AES")) }
    ivHigh = readLong(iv, 0)
    ivLow = readLong(iv, 8)
  }

  /**
   * Decrypts (or encrypts: CTR is symmetric) `data[offset until offset + length]`
   * in place, where `data[offset]` is byte [position] of the plaintext.
   */
  fun apply(data: ByteArray, offset: Int, length: Int, position: Long) {
    if (length <= 0) return
    val firstBlock = position / BLOCK_SIZE
    val skip = (position % BLOCK_SIZE).toInt()
    val blocks = (skip + length + BLOCK_SIZE - 1) / BLOCK_SIZE
    val byteCount = blocks * BLOCK_SIZE
    if (counters.size < byteCount) {
      release()
      counters = ByteArray(byteCount)
      keystream = ByteArray(byteCount)
    }
    fillCounters(firstBlock, blocks)
    val produced = cipher.update(counters, 0, byteCount, keystream, 0)
    check(produced == byteCount) { "AES-ECB keystream: $produced of $byteCount bytes" }
    for (i in 0 until length) {
      data[offset + i] = (data[offset + i].toInt() xor keystream[skip + i].toInt()).toByte()
    }
  }

  /** Zeroes the keystream buffer, which is key-derived. */
  fun release() {
    keystream.fill(0)
  }

  /**
   * Counter blocks IV + first, IV + first + 1, … as 128-bit big-endian
   * integers, carrying from the low half into the high half.
   */
  private fun fillCounters(first: Long, blocks: Int) {
    var low = ivLow + first
    var high = if (java.lang.Long.compareUnsigned(low, ivLow) < 0) ivHigh + 1 else ivHigh
    for (block in 0 until blocks) {
      val base = block * BLOCK_SIZE
      writeLong(counters, base, high)
      writeLong(counters, base + 8, low)
      low += 1
      if (low == 0L) high += 1
    }
  }

  companion object {
    const val BLOCK_SIZE = 16

    private fun readLong(bytes: ByteArray, offset: Int): Long {
      var value = 0L
      for (i in 0 until 8) value = (value shl 8) or (bytes[offset + i].toLong() and 0xFF)
      return value
    }

    private fun writeLong(bytes: ByteArray, offset: Int, value: Long) {
      for (i in 0 until 8) bytes[offset + i] = (value ushr (56 - 8 * i)).toByte()
    }
  }
}
