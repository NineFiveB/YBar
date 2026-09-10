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
    /// Retained: CLLocationManager holds its delegate weakly.
    private var authorizationRelay: LocationAuthorizationRelay?

    public init() {}

    /// Explicit opt-in (`--bar wifi_ssid_prompt=on`): the authorization
    /// dialog's nested run loop starves the daemon's socket while pending,
    /// so it must never fire unattended at boot.
    public func requestLocationAuthorization() {
        if locationManager == nil {
            let manager = CLLocationManager()
            let relay = LocationAuthorizationRelay(provider: self)
            manager.delegate = relay
            authorizationRelay = relay
            locationManager = manager
        }
        guard let locationManager else { return }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Pure: whether an authorization callback is the grant landing. The
    /// first callback after the delegate is set merely reports the status
    /// the process already had (`previous == nil`), and the SSID for that
    /// state is already published; only a transition INTO authorized makes
    /// a readable SSID appear where "connected" was.
    nonisolated static func authorizationUnlocksSSID(
        previous: CLAuthorizationStatus?, current: CLAuthorizationStatus
    ) -> Bool {
        // macOS reports a when-in-use grant as authorizedAlways.
        guard let previous, current == .authorizedAlways else { return false }
        return previous != .authorizedAlways
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
        let info = NetworkProvider.info(
            satisfied: satisfied, isWifi: isWifi,
            ssid: satisfied && isWifi ? NetworkProvider.currentSSID() : nil)
        guard forced || info != lastInfo else { return }
        lastInfo = info
        onEvent?("wifi_change", info)
    }

    /// Pure: the wifi_change INFO — "" offline, the SSID on Wi-Fi when it is
    /// readable, "connected" otherwise (wired, or no Location grant). Split
    /// out for testability.
    nonisolated static func info(satisfied: Bool, isWifi: Bool, ssid: String?) -> String {
        guard satisfied else { return "" }
        if isWifi, let ssid { return ssid }
        return "connected"
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

/// Re-publishes the SSID once the user answers the Location prompt. The grant
/// changes nothing NWPathMonitor watches and the dedupe holds "connected", so
/// without this the network name only appeared on the next path change or a
/// manual `ybar --trigger wifi_change`.
private final class LocationAuthorizationRelay: NSObject, CLLocationManagerDelegate {
    private weak var provider: NetworkProvider?
    private var lastStatus: CLAuthorizationStatus?

    init(provider: NetworkProvider) {
        self.provider = provider
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let unlocks = NetworkProvider.authorizationUnlocksSSID(previous: lastStatus, current: status)
        lastStatus = status
        guard unlocks else { return }
        // Delivered on the run loop of the thread that created the manager — main.
        let provider = self.provider
        MainActor.assumeIsolated {
            provider?.refresh()
        }
    }
}

/// Weak registry so the NWPathMonitor callback (background queue) can reach the
/// main-actor provider without capturing it in a Sendable closure.
@MainActor
final class NetworkProviderRegistry {
    static let shared = NetworkProviderRegistry()
    weak var provider: NetworkProvider?
}
