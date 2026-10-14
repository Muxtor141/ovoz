package uz.sayma.ovoz.engine

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.IOException
import uz.sayma.ovoz.OvozPlayer

/**
 * What the engine needs from the app process: its context, Flutter's asset
 * lookup, and the players alive in it. Installed by `OvozPlugin`, the one
 * class that knows Flutter.
 */
@OptIn(UnstableApi::class)
internal object Ovoz {
  const val TAG = "ovoz"

  private var appContext: Context? = null
  private var assets: FlutterPlugin.FlutterAssets? = null
  private var engines = 0
  private val players = LinkedHashSet<OvozPlayer>()

  val mainHandler = Handler(Looper.getMainLooper())

  val context: Context
    get() = appContext ?: throw IllegalStateException(
      "ovoz: the plugin is not registered with a Flutter engine; create players after the engine starts",
    )

  val isDebuggable: Boolean
    get() = appContext?.let { it.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0 } ?: false

  fun attach(context: Context, flutterAssets: FlutterPlugin.FlutterAssets) {
    appContext = context.applicationContext
    assets = flutterAssets
    engines++
  }

  /**
   * The last Flutter engine went away (the activity was destroyed with its
   * engine). Nothing could cue the next item or answer a lock-screen command
   * any more, so the players stop and release everything.
   */
  fun detach() {
    engines = maxOf(0, engines - 1)
    if (engines > 0) return
    players.toList().forEach { it.dispose() }
    MediaControls.shutDown()
    SessionManager.shutDown()
  }

  fun register(player: OvozPlayer) {
    players += player
  }

  fun unregister(player: OvozPlayer) {
    players -= player
  }

  /**
   * The path of a Flutter asset inside the APK's assets (`flutter_assets/…`),
   * or null if there is no such asset.
   */
  fun assetPath(key: String): String? {
    val path = assets?.getAssetFilePathByName(key) ?: return null
    return try {
      context.assets.open(path).close()
      path
    } catch (_: IOException) {
      null
    }
  }

  /**
   * Engine calls must come from the main isolate, on the platform thread:
   * Dart runs there (merged UI/platform threads), and so does ExoPlayer
   * (IO-01, IO-02). Unlike AVFoundation, ExoPlayer refuses calls from any
   * other thread, so this fails loudly in release builds too.
   */
  fun checkMainThread() {
    if (Looper.myLooper() !== Looper.getMainLooper()) {
      throw IllegalStateException(
        "ovoz: call the engine from the main isolate on the platform thread (IO-01, IO-02). " +
          "Has the app turned off Flutter's merged platform and UI threads?",
      )
    }
  }

  /** Runs [work] on the main thread: at once if already there. */
  fun onMain(work: () -> Unit) {
    if (Looper.myLooper() === Looper.getMainLooper()) work() else mainHandler.post(work)
  }

  fun warn(message: String) {
    Log.w(TAG, message)
  }
}
