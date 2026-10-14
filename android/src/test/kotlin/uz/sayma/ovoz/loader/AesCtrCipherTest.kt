package uz.sayma.ovoz.loader

import java.io.File
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import uz.sayma.ovoz.engine.OvozErrorCode
import uz.sayma.ovoz.engine.OvozIOException

// The vectors the iOS native tests use, written by tool/make_test_vectors.sh
// with demo keys, in Mutolaa's layout among others.
private fun fixture(name: String): ByteArray =
  File(checkNotNull(System.getProperty("ovoz.fixtures")) { "run through Gradle" }, name).readBytes()

private val demoKey = "ovoz-demo-key-16".toByteArray()
private val demoIv = "ovoz-demo-iv--16".toByteArray()
private val key256 = ByteArray(32) { it.toByte() }

private fun cipher(key: ByteArray, iv: ByteArray) = AesCtrCipher(SecureBytes(key), iv)

class AesCtrCipherTest {
  @Test
  fun decryptsTheSeparateIvVector() {
    val data = fixture("sample_separate_iv.mp3.enc")
    cipher(demoKey, demoIv).apply(data, 0, data.size, 0)
    assertArrayEquals(fixture("sample.mp3"), data)
  }

  @Test
  fun randomOffsetsMatchTheWholeFileDecrypt() {
    val cipherText = fixture("sample_separate_iv.mp3.enc")
    val plain = fixture("sample.mp3")
    val cipher = cipher(demoKey, demoIv)
    val random = Random(20261008)
    repeat(500) {
      val start = random.nextInt(cipherText.size - 1)
      val end = minOf(cipherText.size, start + 1 + random.nextInt(70_000))
      // Decrypted in place inside a larger buffer, as ExoPlayer reads.
      val buffer = ByteArray(end - start + 7)
      cipherText.copyInto(buffer, 3, start, end)
      cipher.apply(buffer, 3, end - start, start.toLong())
      assertArrayEquals("range $start until $end", plain.copyOfRange(start, end), buffer.copyOfRange(3, 3 + end - start))
    }
  }

  @Test
  fun counterCarriesAcrossAll128Bits() {
    val data = fixture("sample_carry.mp3.enc")
    cipher(demoKey, ByteArray(16) { 0xFF.toByte() }).apply(data, 0, data.size, 0)
    assertArrayEquals(fixture("sample.mp3"), data)
  }

  @Test
  fun aes256WithTheIvInTheHeader() {
    val file = fixture("sample_ivheader.mp3.enc")
    val body = file.copyOfRange(16, file.size)
    cipher(key256, file.copyOf(16)).apply(body, 0, body.size, 0)
    assertArrayEquals(fixture("sample.mp3"), body)
  }

  @Test
  fun rejectsBadKeyAndIvLengths() {
    for ((key, iv) in listOf(ByteArray(10) to demoIv, demoKey to ByteArray(8))) {
      try {
        cipher(key, iv)
        fail("accepted a ${key.size}-byte key and a ${iv.size}-byte IV")
      } catch (e: OvozIOException) {
        assertEquals(OvozErrorCode.INVALID_CONFIGURATION, e.code)
      }
    }
  }

  @Test
  fun aReleasedKeyCannotMakeACipher() {
    val key = SecureBytes(demoKey)
    key.release()
    try {
      AesCtrCipher(key, demoIv)
      fail("made a cipher from a released key")
    } catch (_: java.io.IOException) {
    }
  }

  @Test
  fun formatSignatures() {
    val mp3 = AudioFormatInfo.named("mp3")!!
    assertTrue(mp3.matches(fixture("sample.mp3")))
    assertFalse(mp3.matches(fixture("sample_separate_iv.mp3.enc")))
    val m4a = byteArrayOf(0, 0, 0, 0x20) + "ftypM4A ".toByteArray()
    assertTrue(AudioFormatInfo.named("m4a")!!.matches(m4a))
    assertTrue(AudioFormatInfo.named("M4B")!!.matches(m4a))
    assertNull(AudioFormatInfo.named("ogg"))
    assertFalse(AudioFormatInfo.named("caf")!!.playableOnAndroid)
    assertTrue(AudioFormatInfo.named("flac")!!.playableOnAndroid)
  }
}
