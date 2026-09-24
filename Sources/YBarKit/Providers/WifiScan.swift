import CoreWLAN
import Foundation
import ObjectiveC

/// One row of a Wi-Fi scan the liquid popup can paint.
/// `rssi == WifiScan.absentRSSI` is a saved personal hotspot that is not
/// currently broadcasting.
struct WifiScanRow: Equatable, Sendable {
    var name: String
    var rssi: Int
    var current: Bool
    var known: Bool
    var hotspot: Bool
    /// Password-protected. Open networks are false so the popup can show
    /// an unlocked icon and offer Connect without a password.
    var secure: Bool

    init(name: String, rssi: Int, current: Bool, known: Bool, hotspot: Bool, secure: Bool = true) {
        self.name = name
        self.rssi = rssi
        self.current = current
        self.known = known
        self.hotspot = hotspot
        self.secure = secure
    }
}

/// In-process Wi-Fi scan and saved-network join.
///
/// `system_profiler` redacts every SSID unless the child itself holds the
/// Location grant. CoreWLAN inside this process does not, so the popup scans
/// here. Joining a preferred network goes through `networksetup`, which uses
/// the saved keychain password and is what wakes a saved iPhone hotspot.
enum WifiScan {
    /// Signal placeholder for a hotspot profile that was not in the scan.
    static let absentRSSI = -999
    /// Exit code of a join the watchdog killed, saved-network and prompted
    /// alike — timeout(1)'s number, so it cannot collide with anything
    /// networksetup itself exits with.
    static let timedOutCode: Int32 = 124
    /// How long a join may run before the watchdog signals `networksetup`:
    /// long enough for a slow association or a hotspot waking from sleep,
    /// short enough that a hung child does not pin the password dialog, or
    /// the utility-queue job behind `wifi_join`, for good.
    static let joinTimeout: TimeInterval = 30
    /// Exit code of a scan whose every SSID was withheld: macOS gates the
    /// names behind the Location grant, which the popup then has to ask for.
    static let redactedCode: Int32 = 3
    /// Name the joined network is listed under when the grant withholds it:
    /// the literal Apple's own tools print, and one the sketchybar port
    /// already treats as a name.
    static let redactedName = "<redacted>"

    struct Sighting: Equatable, Sendable {
        var name: String
        var rssi: Int
        var secure: Bool

        init(name: String, rssi: Int, secure: Bool = true) {
            self.name = name
            self.rssi = rssi
            self.secure = secure
        }
    }

    /// Password security. `.none` alone is an open network. Anything else,
    /// including an unknown mode, is treated as locked.
    static func isSecure(_ network: CWNetwork) -> Bool {
        let locked: [CWSecurity] = [
            .WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal,
            .dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise,
            .enterprise, .wpa3Personal, .wpa3Enterprise, .wpa3Transition,
            .OWE, .oweTransition,
        ]
        if locked.contains(where: { network.supportsSecurity($0) }) { return true }
        return !network.supportsSecurity(.none)
    }

    struct Profile: Equatable, Sendable {
        var name: String
        /// nil: `_isPersonalHotspot` could not be read. Never treated as a hotspot.
        var hotspot: Bool?
    }

    /// Deduped, strongest-signal scan merged with preferred profiles.
    /// Hotspot rows are added only when the flag was actually read as true.
    static func merge(
        sightings: [Sighting],
        currentSSID: String?,
        profiles: [Profile]
    ) -> [WifiScanRow] {
        var best: [String: (rssi: Int, secure: Bool)] = [:]
        for sighting in sightings {
            let name = sanitize(sighting.name)
            guard !name.isEmpty else { continue }
            if let previous = best[name] {
                if sighting.rssi > previous.rssi {
                    best[name] = (sighting.rssi, sighting.secure)
                }
            } else {
                best[name] = (sighting.rssi, sighting.secure)
            }
        }

        var known = Set<String>()
        var hotspotByName: [String: Bool] = [:]
        for profile in profiles {
            let name = sanitize(profile.name)
            guard !name.isEmpty else { continue }
            known.insert(name)
            if profile.hotspot == true {
                hotspotByName[name] = true
            } else if hotspotByName[name] != true {
                hotspotByName[name] = false
            }
        }

        let current = currentSSID.map(sanitize)
        var rows: [WifiScanRow] = []
        var seen = Set<String>()
        for (name, sighting) in best {
            seen.insert(name)
            rows.append(WifiScanRow(
                name: name,
                rssi: sighting.rssi,
                current: name == current,
                known: known.contains(name),
                hotspot: hotspotByName[name] == true,
                secure: sighting.secure))
        }
        for (name, isHotspot) in hotspotByName where isHotspot && !seen.contains(name) {
            // A personal hotspot that is not broadcasting still uses a password.
            rows.append(WifiScanRow(
                name: name,
                rssi: absentRSSI,
                current: name == current,
                known: true,
                hotspot: true,
                secure: true))
        }
        rows.sort { a, b in
            if a.current != b.current { return a.current }
            let aAbsent = a.rssi <= absentRSSI
            let bAbsent = b.rssi <= absentRSSI
            if aAbsent != bAbsent { return !aAbsent }
            if a.rssi != b.rssi { return a.rssi > b.rssi }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return rows
    }

    /// `current \t name \t rssi \t known \t hotspot \t secure`, one network per line.
    static func tsv(_ rows: [WifiScanRow]) -> String {
        rows.map { row in
            "\(row.current ? 1 : 0)\t\(row.name)\t\(row.rssi)\t\(row.known ? 1 : 0)\t\(row.hotspot ? 1 : 0)\t\(row.secure ? 1 : 0)"
        }.joined(separator: "\n")
    }

    static func sanitize(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pure: whether a pass came back with every SSID withheld. Without the
    /// Location grant CoreWLAN answers nil for each network's name, so
    /// networks on the air that none could be read from is the missing
    /// grant; an empty pass (Wi-Fi off, or the scan failing) is not.
    /// Detected from the result rather than asked of CLLocationManager,
    /// which must never be touched unattended (see NetworkProvider).
    static func isRedacted(scanned: Int, named: Int) -> Bool {
        scanned > 0 && named == 0
    }

    /// Blocking scan. Call off the main thread; a pass takes seconds.
    /// The code is `redactedCode` when no SSID could be read, else 0.
    static func perform() -> (output: String, code: Int32) {
        guard let iface = CWWiFiClient.shared().interface() else { return ("", 0) }
        let current = iface.ssid().map(sanitize)
        let networks: Set<CWNetwork>
        do {
            networks = try iface.scanForNetworks(withSSID: nil)
        } catch {
            networks = []
        }
        var sightings: [Sighting] = []
        sightings.reserveCapacity(networks.count)
        for network in networks {
            guard let name = network.ssid, !name.isEmpty else { continue }
            sightings.append(Sighting(
                name: name, rssi: network.rssiValue, secure: isSecure(network)))
        }
        if isRedacted(scanned: networks.count, named: sightings.count) {
            // The saved profiles lose their names the same way, so there is
            // nothing to list; the popup says what to allow instead. Only
            // the names are gated, though: the interface still says whether
            // it is joined, so the current network keeps its row under the
            // placeholder — Connected, Disconnect and the pill stay right,
            // and Lua can tell Wi-Fi from a wired path without probing.
            // interfaceMode() is that signal. CWInterface.h: "Returns
            // kCWInterfaceModeNone if an error occurs, or if the interface
            // is not participating in a Wi-Fi network", and .station is
            // "participating in an infrastructure network as a non-AP
            // station"; unlike ssid(), bssid() and countryCode() it carries
            // no Location note, and it reads .station from this
            // unprivileged process on a joined interface. rssiValue() and
            // noiseMeasurement() are grant-free too, but each answers 0 for
            // a failed read as well as for "not joined", so requiring one
            // would drop the row on a bad reading (currentSighting only
            // papers over that 0 with -50).
            var rows: [WifiScanRow] = []
            if iface.interfaceMode() == .station {
                let sighting = currentSighting(on: iface, name: redactedName)
                rows.append(WifiScanRow(
                    name: sighting.name, rssi: sighting.rssi,
                    current: true, known: true, hotspot: false, secure: sighting.secure))
            }
            return (tsv(rows), redactedCode)
        }
        // Read after the redaction check: a redacted pass lists no profile,
        // so the ObjC ivar peeks behind readProfiles would be spent on
        // a result that path throws away.
        let profiles = readProfiles(on: iface)
        if let current, !current.isEmpty,
           !sightings.contains(where: { sanitize($0.name) == current }) {
            sightings.append(currentSighting(on: iface, name: current))
        }
        return (tsv(merge(sightings: sightings, currentSSID: current, profiles: profiles)), 0)
    }

    /// The joined network as the interface itself reports it, for when the
    /// scan did not list it. `rssiValue()` is 0 with no reading; -50 keeps
    /// the signal fan drawn.
    private static func currentSighting(on iface: CWInterface, name: String) -> Sighting {
        let rssi = iface.rssiValue()
        return Sighting(name: name, rssi: rssi == 0 ? -50 : rssi, secure: iface.security() != .none)
    }

    /// Arguments for `networksetup -setairportnetwork`. A password is never
    /// placed here: `"-"` tells networksetup to read it from stdin.
    static func airportJoinArguments(interface: String, name: String, password: String?) -> [String] {
        if password != nil {
            return ["-setairportnetwork", interface, name, "-"]
        }
        return ["-setairportnetwork", interface, name]
    }

    /// Remove a secret if a child echoed it. An empty password is not a
    /// pattern, so it cannot blank out the whole message.
    static func redacted(_ output: String, password: String?) -> String {
        guard let password, !password.isEmpty else { return output }
        return output.replacingOccurrences(of: password, with: "")
    }

    /// Pure: whether `networksetup -setairportnetwork` refused the join.
    /// It prints nothing on success, but exits 0 for several refusals
    /// ("Could not find network X.", "You cannot join a network when Wi-Fi
    /// power is off.", "All Wi-Fi network services are disabled."), so any
    /// output at all is a refusal — not only the "Failed to join" line.
    static func joinRejected(code: Int32, output: String) -> Bool {
        code != 0 || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Join a network. With `password == nil`, `networksetup` uses the
    /// keychain and can wake a saved personal hotspot. A non-nil password is
    /// written to the child's stdin and is not returned in `output`.
    ///
    /// The code is 0 only when `networksetup` exited 0 and printed nothing.
    /// A pre-spawn failure — an empty name, no Wi-Fi interface, the spawn
    /// itself — is 1 with a "[!]" line as the output; a non-zero status
    /// passes through; a refusal printed while exiting 0 ("Could not find
    /// network …") becomes 1 (`joinRejected`). `timedOutCode` is the
    /// watchdog, on both paths: a child still running after `joinTimeout`
    /// is killed, and the output is then empty.
    static func join(ssid: String, password: String? = nil) -> (output: String, code: Int32) {
        let name = sanitize(ssid)
        guard !name.isEmpty else { return ("[!] wifi_join expects a network name", 1) }
        guard let interface = CWWiFiClient.shared().interface()?.interfaceName, !interface.isEmpty else {
            return ("[!] no Wi-Fi interface", 1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = airportJoinArguments(interface: interface, name: name, password: password)
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let inputPipe = Pipe()
        if password != nil {
            process.standardInput = inputPipe
        }
        do {
            try process.run()
        } catch {
            return ("[!] \(error.localizedDescription)", 1)
        }
        if let password {
            var bytes = Data(password.utf8)
            bytes.append(0x0A)
            let writer = inputPipe.fileHandleForWriting
            do {
                try writer.write(contentsOf: bytes)
                try writer.close()
            } catch {
                try? writer.close()
                process.terminate()
                bytes.resetBytes(in: 0..<bytes.count)
                return ("[!] could not join \(name)", 1)
            }
            bytes.resetBytes(in: 0..<bytes.count)
        }
        let result = reap(process, output: outputPipe, timeout: joinTimeout)
        if result.code == timedOutCode { return result }
        if let password {
            // Nothing the child printed comes back on this path: it may
            // have echoed the secret, and the prompt only reads the code.
            let cleaned = redacted(result.output, password: password)
            if joinRejected(code: result.code, output: cleaned) {
                return ("", result.code == 0 ? 1 : result.code)
            }
            return ("", 0)
        }
        if joinRejected(code: result.code, output: result.output) {
            return (result.output.isEmpty ? "[!] could not join \(name)" : result.output,
                    result.code == 0 ? 1 : result.code)
        }
        return ("", 0)
    }

    /// Everything after the spawn, shared by the saved-network join and the
    /// password prompt's: arm the watchdog, drain the child's output, read
    /// its exit. A child still running `timeout` seconds in gets SIGTERM,
    /// then SIGKILL if it shrugs that off (`ProcessBox`); it dies of the
    /// signal, and the result is then `("", timedOutCode)` — a signal death
    /// is the watchdog, not a verdict on the join, and whatever the child
    /// managed to print first is not one either. Otherwise the output is
    /// the child's, trimmed, next to its exit status as it was: the verdict
    /// (`joinRejected`) is the caller's.
    static func reap(
        _ process: Process, output pipe: Pipe, timeout: TimeInterval
    ) -> (output: String, code: Int32) {
        let box = ProcessBox(process: process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            box.terminateIfRunning()
        }
        // Drain before waiting: a child blocked writing a full pipe never
        // exits, and the read returns once the child is gone either way.
        let raw = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal {
            return ("", timedOutCode)
        }
        return (raw, process.terminationStatus)
    }

    /// Drop the current association. Wi-Fi stays on; this is not a power toggle.
    static func disconnect() -> (output: String, code: Int32) {
        guard let iface = CWWiFiClient.shared().interface() else {
            return ("[!] no Wi-Fi interface", 1)
        }
        iface.disassociate()
        return ("", 0)
    }

    private static func readProfiles(on iface: CWInterface) -> [Profile] {
        guard let ordered = iface.configuration()?.networkProfiles else { return [] }
        let flagName = "_isPersonalHotspot"
        let readable = class_getInstanceVariable(CWNetworkProfile.self, flagName) != nil
        var profiles: [Profile] = []
        for case let profile as CWNetworkProfile in ordered.array {
            guard let name = profile.ssid, !name.isEmpty else { continue }
            let hotspot: Bool? = readable ? boolIvar(profile, name: flagName) : nil
            profiles.append(Profile(name: name, hotspot: hotspot))
        }
        return profiles
    }

    /// Pure: whether an ivar's ObjC type encoding is a one-byte `BOOL` —
    /// "B" (C99 bool, arm64) or "c" (signed char, x86_64). Anything else,
    /// including no encoding at all, is refused so a changed layout is
    /// never read as a flag.
    static func isBoolIvarEncoding(_ encoding: String?) -> Bool {
        encoding == "B" || encoding == "c"
    }

    /// Read-only ObjC-runtime peek at a `BOOL` ivar. The SDK header declares
    /// `_isPersonalHotspot` under `@private`, and the accessor that exists
    /// for it is private too, so there is no supported way to ask. The read
    /// is presence- and type-checked and degrades to nil — no hotspot rows —
    /// when either check fails.
    private static func boolIvar(_ object: AnyObject, name: String) -> Bool? {
        guard let ivar = class_getInstanceVariable(type(of: object), name),
              isBoolIvarEncoding(ivar_getTypeEncoding(ivar).map { String(cString: $0) })
        else { return nil }
        let pointer = Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar))
        return pointer.load(as: UInt8.self) != 0
    }
}
