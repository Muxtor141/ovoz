package uz.sayma.ovoz.loader

/**
 * What the engine knows about a declared audio format.
 *
 * ExoPlayer sniffs the decrypted bytes, so the declaration matters less than
 * on iOS. It drives the wrong-key check (ENC-07): a correctly decrypted file
 * starts with its format's signature, a wrongly decrypted one starts with
 * noise. The table is the iOS engine's.
 */
internal class AudioFormatInfo private constructor(val name: String) {
  /** Media3 has no AIFF or CAF extractor. */
  val playableOnAndroid: Boolean get() = name != "aiff" && name != "caf"

  /**
   * Whether [header] (the first plaintext bytes) can start a file of this
   * format. Lenient where formats are: an MP3 may start with an ID3 tag or a
   * bare frame, an MP4 with any top-level box.
   */
  fun matches(header: ByteArray): Boolean {
    val b = header.copyOf(minOf(header.size, SIGNATURE_LENGTH))
    if (b.size < 4) return false
    fun ascii(text: String, at: Int): Boolean {
      val expected = text.toByteArray(Charsets.US_ASCII)
      if (b.size < at + expected.size) return false
      return expected.indices.all { b[at + it] == expected[it] }
    }
    fun byte(i: Int) = b[i].toInt() and 0xFF
    return when (name) {
      "mp3" -> ascii("ID3", 0) || (byte(0) == 0xFF && byte(1) and 0xE0 == 0xE0)
      "aac" -> ascii("ID3", 0) || (byte(0) == 0xFF && byte(1) and 0xF6 == 0xF0)
      "m4a" -> listOf("ftyp", "moov", "mdat", "free", "skip", "wide", "pnot").any { ascii(it, 4) }
      "wav" -> ascii("RIFF", 0) || ascii("RF64", 0)
      "aiff" -> ascii("FORM", 0)
      "flac" -> ascii("fLaC", 0) || ascii("ID3", 0)
      "caf" -> ascii("caff", 0)
      else -> true
    }
  }

  override fun toString(): String = name

  companion object {
    /** Plaintext bytes needed to check the signature. */
    const val SIGNATURE_LENGTH = 12

    fun named(name: String): AudioFormatInfo? = when (name.lowercase()) {
      "mp3" -> AudioFormatInfo("mp3")
      "aac" -> AudioFormatInfo("aac")
      "m4a", "mp4", "m4b", "alac" -> AudioFormatInfo("m4a")
      "wav" -> AudioFormatInfo("wav")
      "aiff", "aif" -> AudioFormatInfo("aiff")
      "flac" -> AudioFormatInfo("flac")
      "caf" -> AudioFormatInfo("caf")
      else -> null
    }
  }
}
