package uz.sayma.ovoz.loader

import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.zip.GZIPOutputStream

/**
 * A small HTTP server on the loopback interface that serves one body by byte
 * range and refuses requests without the bearer token, like a content server
 * (and like the iOS native tests' `RangeServer`). [mode] makes it misbehave
 * the ways a real server can.
 */
internal class RangeServer(private val body: ByteArray) : Closeable {
  enum class Mode {
    /** 206 with exactly the range asked for. */
    RANGES,

    /** 200 with the whole body, whatever was asked. */
    IGNORE_RANGES,

    /** 206, gzip-compressed. */
    GZIP,

    /** 206 starting one byte later than asked. */
    WRONG_RANGE,
  }

  @Volatile var mode = Mode.RANGES

  /** "GET /file bytes=0-27", one per request. */
  val requests = CopyOnWriteArrayList<String>()

  private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))

  init {
    Thread(::serve, "RangeServer").apply { isDaemon = true }.start()
  }

  val url: String get() = "http://127.0.0.1:${socket.localPort}/file"

  override fun close() = socket.close()

  private fun serve() {
    while (!socket.isClosed) {
      val client = try {
        socket.accept()
      } catch (_: IOException) {
        return
      }
      Thread { handle(client) }.apply { isDaemon = true }.start()
    }
  }

  private fun handle(client: Socket) = client.use {
    val input = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.ISO_8859_1))
    val requestLine = input.readLine() ?: return
    val headers = mutableMapOf<String, String>()
    while (true) {
      val line = input.readLine() ?: break
      if (line.isEmpty()) break
      val colon = line.indexOf(':')
      if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
    }
    val range = headers["range"]
    requests += requestLine.substringBeforeLast(" HTTP/") + (range?.let { " $it" } ?: "")
    val out = client.getOutputStream()
    if (headers["authorization"] != "Bearer $TOKEN") {
      respond(out, "401 Unauthorized", ByteArray(0))
      return
    }
    var start = 0
    var end = body.size - 1
    RANGE.find(range.orEmpty())?.let { match ->
      start = match.groupValues[1].toInt()
      if (match.groupValues[2].isNotEmpty()) end = minOf(match.groupValues[2].toInt(), body.size - 1)
    }
    when (mode) {
      Mode.IGNORE_RANGES -> respond(out, "200 OK", body)
      Mode.RANGES, Mode.WRONG_RANGE, Mode.GZIP -> {
        val reportedStart = if (mode == Mode.WRONG_RANGE) start + 1 else start
        var slice = body.copyOfRange(start, end + 1)
        var extra = "Content-Range: bytes $reportedStart-$end/${body.size}\r\n"
        if (mode == Mode.GZIP) {
          slice = gzip(slice)
          extra += "Content-Encoding: gzip\r\n"
        }
        respond(out, "206 Partial Content", slice, extra)
      }
    }
  }

  private fun respond(out: OutputStream, status: String, content: ByteArray, extra: String = "") {
    val head = "HTTP/1.1 $status\r\nAccept-Ranges: bytes\r\nContent-Type: audio/mpeg\r\n" +
      "Content-Length: ${content.size}\r\nConnection: close\r\n$extra\r\n"
    out.write(head.toByteArray(Charsets.ISO_8859_1))
    out.write(content)
    out.flush()
  }

  private fun gzip(bytes: ByteArray): ByteArray {
    val buffer = ByteArrayOutputStream()
    GZIPOutputStream(buffer).use { it.write(bytes) }
    return buffer.toByteArray()
  }

  companion object {
    const val TOKEN = "demo-token"
    private val RANGE = Regex("""bytes=(\d+)-(\d*)""")
  }
}
