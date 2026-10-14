package uz.sayma.ovoz.loader

import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceUtil
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.FileDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.random.Random
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import uz.sayma.ovoz.engine.OvozErrorCode
import uz.sayma.ovoz.engine.OvozErrors
import uz.sayma.ovoz.engine.OvozIOException

// Demo key and IV (tool/make_test_vectors.sh), in Mutolaa's layout.
private val demoKey = "ovoz-demo-key-16".toByteArray()
private val demoIv = "ovoz-demo-iv--16".toByteArray()
private val key256 = ByteArray(32) { it.toByte() }

/**
 * The decrypting data source with Media3's own file and HTTP sources, and
 * ExoPlayer playing through it: what the iOS native tests check for the
 * resource loader and byte sources.
 */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class AesCtrDataSourceTest {
  private val context = InstrumentationRegistry.getInstrumentation().context
  private val servers = mutableListOf<RangeServer>()

  @After
  fun closeServers() = servers.forEach(RangeServer::close)

  private fun fixture(name: String): ByteArray = context.assets.open(name).use { it.readBytes() }

  /** A fixture as a file, as a download would be. */
  private fun file(name: String): Uri {
    val file = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, name)
    file.writeBytes(fixture(name))
    return Uri.fromFile(file)
  }

  private fun server(name: String) = RangeServer(fixture(name)).also { servers += it }

  private fun http(token: String? = RangeServer.TOKEN) = DefaultHttpDataSource.Factory()
    .setDefaultRequestProperties(token?.let { mapOf("Authorization" to "Bearer $it") } ?: emptyMap())

  private fun source(
    upstream: DataSource.Factory,
    key: ByteArray = demoKey,
    iv: ByteArray? = demoIv,
    dataOffset: Long = 0,
    remote: Boolean = false,
  ): DataSource.Factory = AesCtrDataSource.Factory(
    upstream,
    EncryptedResource(EncryptionLayout(SecureBytes(key), iv, dataOffset), AudioFormatInfo.named("mp3")!!, remote),
  )

  private fun read(factory: DataSource.Factory, uri: Uri, position: Long = 0, length: Long = C.LENGTH_UNSET.toLong()): ByteArray {
    val source = factory.createDataSource()
    try {
      source.open(DataSpec.Builder().setUri(uri).setPosition(position).setLength(length).build())
      return DataSourceUtil.readToEnd(source)
    } finally {
      source.close()
    }
  }

  private fun assertFails(code: OvozErrorCode, block: () -> Unit) {
    try {
      block()
      fail("expected $code")
    } catch (e: OvozIOException) {
      assertEquals(e.message, code, e.code)
    }
  }

  @Test
  fun decryptsALocalFileWholeAndInRanges() {
    val plain = fixture("sample.mp3")
    val uri = file("sample_separate_iv.mp3.enc")
    val factory = source(FileDataSource.Factory())
    assertArrayEquals(plain, read(factory, uri))
    val random = Random(20261008)
    repeat(100) {
      val start = random.nextInt(plain.size - 1)
      val length = 1 + random.nextInt(minOf(70_000, plain.size - start))
      assertArrayEquals("range $start+$length", plain.copyOfRange(start, start + length), read(factory, uri, start.toLong(), length.toLong()))
    }
  }

  @Test
  fun readsTheIvFromTheFilesHeader() {
    val factory = source(FileDataSource.Factory(), key = key256, iv = null, dataOffset = 16)
    assertArrayEquals(fixture("sample.mp3"), read(factory, file("sample_ivheader.mp3.enc")))
  }

  @Test
  fun aWrongKeyFailsAtOnceAndEveryTime() {
    val uri = file("sample_separate_iv.mp3.enc")
    val factory = source(FileDataSource.Factory(), key = ByteArray(16))
    assertFails(OvozErrorCode.DECRYPTION) { read(factory, uri) }
    assertFails(OvozErrorCode.DECRYPTION) { read(factory, uri, position = 4096) }
  }

  @Test
  fun streamsByteRangesWithTheAppsHeaders() {
    val plain = fixture("sample.mp3")
    val server = server("sample_separate_iv.mp3.enc")
    val factory = source(http(), remote = true)
    val uri = Uri.parse(server.url)
    assertArrayEquals(plain, read(factory, uri))
    assertArrayEquals(plain.copyOfRange(100_000, 100_500), read(factory, uri, 100_000, 500))
    assertTrue(server.requests.toString(), server.requests.all { it.contains("bytes=") })
  }

  @Test
  fun aServerThatIgnoresRangesIsReported() {
    val server = server("sample_separate_iv.mp3.enc").apply { mode = RangeServer.Mode.IGNORE_RANGES }
    assertFails(OvozErrorCode.RANGE_NOT_SUPPORTED) { read(source(http(), remote = true), Uri.parse(server.url)) }
  }

  @Test
  fun aCompressedAnswerIsReported() {
    val server = server("sample_separate_iv.mp3.enc").apply { mode = RangeServer.Mode.GZIP }
    assertFails(OvozErrorCode.RANGE_NOT_SUPPORTED) { read(source(http(), remote = true), Uri.parse(server.url)) }
  }

  @Test
  fun anAnswerForAnotherRangeIsReported() {
    val server = server("sample_separate_iv.mp3.enc").apply { mode = RangeServer.Mode.WRONG_RANGE }
    assertFails(OvozErrorCode.RANGE_NOT_SUPPORTED) { read(source(http(), remote = true), Uri.parse(server.url)) }
  }

  @Test
  fun aRefusedRequestMeansTheSourceIsNotThere() {
    val server = server("sample_separate_iv.mp3.enc")
    try {
      read(source(http(token = null), remote = true), Uri.parse(server.url))
      fail("expected a 401")
    } catch (e: HttpDataSource.InvalidResponseCodeException) {
      assertEquals(401, e.responseCode)
      assertEquals(OvozErrorCode.SOURCE_NOT_FOUND, OvozErrors.classify(e, remote = true).code)
    }
  }

  @Test
  fun exoPlayerPlaysAndSeeksInsideAnEncryptedFile() {
    val thread = HandlerThread("player").apply { start() }
    val handler = Handler(thread.looper)
    fun <T> onPlayer(block: () -> T): T {
      var result: Result<T>? = null
      val done = CountDownLatch(1)
      handler.post {
        result = runCatching(block)
        done.countDown()
      }
      assertTrue(done.await(10, TimeUnit.SECONDS))
      return result!!.getOrThrow()
    }
    fun until(timeoutMs: Long = 10_000, condition: () -> Boolean) {
      val deadline = System.currentTimeMillis() + timeoutMs
      while (!onPlayer(condition)) {
        if (System.currentTimeMillis() > deadline) fail("condition not met in $timeoutMs ms")
        Thread.sleep(50)
      }
    }

    val uri = file("sample_separate_iv.mp3.enc")
    val player = onPlayer {
      ExoPlayer.Builder(context).setLooper(thread.looper).build().apply {
        volume = 0f
        val factory = DefaultMediaSourceFactory(source(FileDataSource.Factory()), DefaultExtractorsFactory())
        setMediaSource(factory.createMediaSource(MediaItem.fromUri(uri)))
        prepare()
      }
    }
    try {
      until { player.playbackState == Player.STATE_READY }
      // sample.mp3 is 11.73 s long.
      val duration = onPlayer { player.duration }
      assertTrue("duration $duration", abs(duration - 11_729) < 150)
      onPlayer { player.seekTo(10_000) }
      until { player.playbackState == Player.STATE_READY }
      val position = onPlayer { player.currentPosition }
      assertTrue("position $position", abs(position - 10_000) < 100)
      onPlayer { player.play() }
      until { player.currentPosition > 10_400 }
      until { player.playbackState == Player.STATE_ENDED }
      assertEquals(null, onPlayer { player.playerError })
    } finally {
      onPlayer { player.release() }
      thread.quitSafely()
    }
  }
}
