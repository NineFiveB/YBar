import CoreLocation
import CoreWLAN
import Foundation
import Network

/// Connectivity via public NWPathMonitor, lazily armed on the first
/// `wifi_change` subscription. SSID via CoreWLAN needs Core Location
/// authorization on modern macOS, requested here on first arm (the app
/// bundle carries the usage description); without the grant it degrades to
/// "connected"/"" — no `ipconfig` hacks.
@MainActor
public final class NetworkProvider {
    public var onEvent: ((_ name: String, _ info: String) -> Void)?

    private var monitor: NWPathMonitor?
    private var lastInfo: String?
    /// Retained: authorization callbacks die with a released manager.
    private var locationManager: CLLocationManager?

    public init() {}

    /// Explicit opt-in (`--bar wifi_ssid_prompt=on`): the authorization
    /// dialog's nested run loop starves the daemon's socket while pending,
    /// so it must never fire unattended at boot.
    public func requestLocationAuthorization() {
        if locationManager == nil { locationManager = CLLocationManager() }
        guard let locationManager else { return }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

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
