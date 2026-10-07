import Foundation
import Network

/// Whether the device has a network, and when that changes: one coming back,
/// going away, or moving to another interface (Wi-Fi to cellular). One for
/// every player; it reports on the main thread, only changes.
///
/// A fact, not a decision: what a player does about it is Dart's call.
final class OvozNetworkMonitor {
  static let shared = OvozNetworkMonitor()

  private let monitor = NWPathMonitor()
  private let players = NSHashTable<OvozPlayer>.weakObjects()
  private var last: (available: Bool, interface: NWInterface.InterfaceType?)?

  /// The last report; true until the first one arrives, so that nothing waits
  /// on a network it was never told is missing.
  private(set) var isAvailable = true

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let available = path.status == .satisfied
      let interface = Self.interfaces.first { path.usesInterfaceType($0) }
      onMain { self?.update(available: available, interface: interface) }
    }
    monitor.start(queue: DispatchQueue(label: "uz.sayma.ovoz.network"))
  }

  private static let interfaces: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .other]

  func register(_ player: OvozPlayer) { players.add(player) }

  func unregister(_ player: OvozPlayer) { players.remove(player) }

  private func update(available: Bool, interface: NWInterface.InterfaceType?) {
    if let last, last.available == available, last.interface == interface { return }
    let first = last == nil
    last = (available, interface)
    isAvailable = available
    // A working network at the start changes nothing anyone assumed.
    if first, available { return }
    for player in players.allObjects { player.networkChanged(available: available) }
  }
}
