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

    /// Reads the SSID and hands it back on the main actor. The read is a
    /// synchronous XPC round trip to the Wi-Fi daemon, and that daemon can
    /// take seconds — minutes, while it is busy with a peer-to-peer link such
    /// as Sidecar or AirPlay — to answer. Made on the main thread it froze
    /// the whole bar for as long: no clock, no clicks, no socket. So it runs
    /// on a queue of its own and only the answer comes back here. Injectable
    /// so the sequencing below is testable without a Wi-Fi daemon.
    var readSSID: (_ completion: @escaping @MainActor @Sendable (String?) -> Void) -> Void = { completion in
        NetworkProvider.ssidQueue.async {
            let ssid = NetworkProvider.currentSSID()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(ssid) }
            }
        }
    }
    private static let ssidQueue = DispatchQueue(label: "com.ybar.network.ssid", qos: .utility)
    /// Bumped by every publish: an SSID read answers the state it was started
    /// for, and only the newest state may speak.
    private var generation = 0
    /// One read at a time: a stalled daemon must not collect a queue of them.
    private var ssidReadInFlight = false
    /// Whether the newest state is one that wants an SSID (on Wi-Fi, online).
    private var latestWantsSSID = false
    /// A forced publish must emit even when nothing changed, and it must
    /// survive being overtaken while its read is still out.
    private var forcedPending = false
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
        generation += 1
        forcedPending = forcedPending || forced
        latestWantsSSID = satisfied && isWifi
        guard latestWantsSSID else {
            // Offline or wired: nothing to read, the answer is known now. A
            // read still out for an older state is dropped when it lands.
            deliver(NetworkProvider.info(satisfied: satisfied, isWifi: isWifi, ssid: nil))
            return
        }
        // A read already out answers an older state; when it lands it sees
        // the newer generation and starts the one this state is owed.
        guard !ssidReadInFlight else { return }
        startSSIDRead()
    }

    private func startSSIDRead() {
        ssidReadInFlight = true
        let started = generation
        readSSID { [weak self] ssid in
            self?.finishSSIDRead(started: started, ssid: ssid)
        }
    }

    private func finishSSIDRead(started: Int, ssid: String?) {
        ssidReadInFlight = false
        guard started == generation else {
            // The network changed while the read was out. Its answer is for
            // a state that is gone; read again only if the newest wants one.
            if latestWantsSSID { startSSIDRead() }
            return
        }
        deliver(NetworkProvider.info(satisfied: true, isWifi: true, ssid: ssid))
    }

    private func deliver(_ info: String) {
        guard forcedPending || info != lastInfo else { return }
        forcedPending = false
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
    /// Blocks on the Wi-Fi daemon: never call it on the main thread.
    nonisolated public static func currentSSID() -> String? {
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
