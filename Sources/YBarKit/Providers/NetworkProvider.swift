import CoreWLAN
import Foundation
import Network

/// Connectivity via public NWPathMonitor, lazily armed on the first
/// `wifi_change` subscription. SSID via CoreWLAN is best-effort: on modern
/// macOS it returns nil without Core Location authorization (which needs a real
/// app bundle — planned for the .app packaging milestone). Degrades to
/// "connected"/"" like the architecture doc prescribes; no `ipconfig` hacks.
@MainActor
public final class NetworkProvider {
    public var onEvent: ((_ name: String, _ info: String) -> Void)?

    private var monitor: NWPathMonitor?
    private var lastInfo: String?

    public init() {}

    public func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let isWifi = path.usesInterfaceType(.wifi)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NetworkProviderRegistry.shared.provider?.publish(
                        satisfied: satisfied, isWifi: isWifi, forced: false)
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.monitor = monitor
        NetworkProviderRegistry.shared.provider = self
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
    }

    public func publish(satisfied: Bool, isWifi: Bool, forced: Bool) {
        let info: String
        if satisfied {
            if isWifi, let ssid = NetworkProvider.currentSSID() {
                info = ssid
            } else {
                info = "connected"
            }
        } else {
            info = ""
        }
        guard forced || info != lastInfo else { return }
        lastInfo = info
        onEvent?("wifi_change", info)
    }

    public func refresh() {
        guard let path = monitor?.currentPath else { return }
        publish(satisfied: path.status == .satisfied,
                isWifi: path.usesInterfaceType(.wifi),
                forced: true)
    }

    /// Requires Location authorization on macOS 14+; returns nil without it.
    public static func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }
}

/// Weak registry so the NWPathMonitor callback (background queue) can reach the
/// main-actor provider without capturing it in a Sendable closure.
@MainActor
final class NetworkProviderRegistry {
    static let shared = NetworkProviderRegistry()
    weak var provider: NetworkProvider?
}
