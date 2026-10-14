package uz.sayma.ovoz.engine

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import uz.sayma.ovoz.OvozPlayer

/**
 * Whether the device has a network, and when that changes: one coming back,
 * going away, or moving to another interface (Wi-Fi to cellular). One for
 * every player; it reports on the main thread, only changes.
 *
 * A fact, not a decision: what a player does about it is Dart's call.
 */
internal object NetworkMonitor {
  private enum class Transport { WIFI, CELLULAR, ETHERNET, OTHER }

  private val players = LinkedHashSet<OvozPlayer>()
  private var started = false
  private var last: Pair<Boolean, Transport?>? = null

  /**
   * The last report; true until the first one, so that nothing waits on a
   * network it was never told is missing.
   */
  var isAvailable = true
    private set

  fun register(player: OvozPlayer) {
    players += player
    start()
  }

  fun unregister(player: OvozPlayer) {
    players -= player
  }

  private fun start() {
    if (started) return
    started = true
    val connectivity = Ovoz.context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    try {
      // The state now: without a default network no callback would come.
      refresh(connectivity)
      if (Build.VERSION.SDK_INT >= 24) {
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
          override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            val available = capabilities.hasInternet()
            val transport = capabilities.transport()
            Ovoz.onMain { update(available, transport) }
          }

          override fun onLost(network: Network) {
            Ovoz.onMain { update(false, null) }
          }
        })
      } else {
        // Android 6.0 has no default-network callback: any network's change
        // is the cue to read the active one again.
        connectivity.registerNetworkCallback(
          NetworkRequest.Builder().build(),
          object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = refresh(connectivity)

            override fun onLost(network: Network) = refresh(connectivity)

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
              refresh(connectivity)
          },
        )
      }
    } catch (e: SecurityException) {
      // ACCESS_NETWORK_STATE, which the plugin's manifest declares, was removed.
      Ovoz.warn("ovoz: cannot watch the network ($e); players will not hear when it comes back")
    }
  }

  /** Reads the active network, on any thread, and reports it on the main one. */
  private fun refresh(connectivity: ConnectivityManager) {
    val capabilities = connectivity.activeNetwork?.let { connectivity.getNetworkCapabilities(it) }
    val available = capabilities.hasInternet()
    val transport = capabilities.transport()
    Ovoz.onMain { update(available, transport) }
  }

  private fun update(available: Boolean, transport: Transport?) {
    val next = available to if (available) transport else null
    if (last == next) return
    val first = last == null
    last = next
    isAvailable = available
    // A working network at the start changes nothing anyone assumed.
    if (first && available) return
    players.toList().forEach { it.networkChanged(available) }
  }

  private fun NetworkCapabilities?.hasInternet(): Boolean =
    this?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true

  private fun NetworkCapabilities?.transport(): Transport? = when {
    this == null -> null
    hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Transport.WIFI
    hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Transport.CELLULAR
    hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Transport.ETHERNET
    else -> Transport.OTHER
  }
}
