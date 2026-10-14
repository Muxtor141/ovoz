package uz.sayma.ovoz

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import uz.sayma.ovoz.engine.MediaControls

/**
 * The foreground service that keeps playback going with the screen off and
 * the app in the background, and shows the media notification. Media3 starts
 * it in the foreground when the player that owns the media controls plays,
 * and lets it go when playback stops.
 *
 * The app declares it in its manifest (D-16), with the `mediaPlayback`
 * foreground service type; see the README. An app icon for the notification
 * can be provided as the drawable `ovoz_notification_icon`.
 */
@OptIn(UnstableApi::class)
class OvozPlaybackService : MediaSessionService() {
  override fun onCreate() {
    super.onCreate()
    // A player that stops or loses the controls takes the notification away
    // with it; one that failed stays, paused (the session shows it ready).
    setShowNotificationForIdlePlayer(SHOW_NOTIFICATION_FOR_IDLE_PLAYER_NEVER)
    val notifications = DefaultMediaNotificationProvider.Builder(this).build()
    @Suppress("DiscouragedApi")
    val icon = resources.getIdentifier("ovoz_notification_icon", "drawable", packageName)
    if (icon != 0) notifications.setSmallIcon(icon)
    setMediaNotificationProvider(notifications)
    MediaControls.serviceCreated(this)?.let(::addSession)
  }

  override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = MediaControls.session

  override fun onDestroy() {
    MediaControls.serviceDestroyed(this)
    super.onDestroy()
  }

  companion object {
    /**
     * Whether the app declares the service as a media-playback foreground
     * service with the permissions that needs.
     */
    @Suppress("DEPRECATION")
    fun isDeclared(context: Context): Boolean {
      val packages = context.packageManager
      val info = try {
        packages.getServiceInfo(ComponentName(context, OvozPlaybackService::class.java), 0)
      } catch (_: PackageManager.NameNotFoundException) {
        return false
      }
      if (Build.VERSION.SDK_INT >= 29 &&
        info.foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK == 0
      ) {
        return false
      }
      val requested = packages.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        .requestedPermissions?.toSet().orEmpty()
      if ("android.permission.FOREGROUND_SERVICE" !in requested) return false
      return Build.VERSION.SDK_INT < 34 || "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" in requested
    }
  }
}
