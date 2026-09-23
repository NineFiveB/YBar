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

    /// Blocking scan. Call off the main thread; a pass takes seconds.
    static func perform() -> String {
        guard let iface = CWWiFiClient.shared().interface() else { return "" }
        let current = iface.ssid().map(sanitize)
        let profiles = readProfiles(on: iface)
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
        if let current, !current.isEmpty,
           !sightings.contains(where: { sanitize($0.name) == current }) {
            let rssi = iface.rssiValue()
            let secure = iface.security() != .none
            sightings.append(Sighting(
                name: current, rssi: rssi == 0 ? -50 : rssi, secure: secure))
        }
        return tsv(merge(sightings: sightings, currentSSID: current, profiles: profiles))
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
        // A hung association must not pin the password dialog forever.
        if password != nil {
            let box = ProcessBox(process: process)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                box.terminateIfRunning()
            }
        }
        let raw = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        let code = process.terminationStatus
        if password != nil {
            let cleaned = redacted(raw, password: password)
            if joinRejected(code: code, output: cleaned) {
                return ("", code == 0 ? 1 : code)
            }
            return ("", 0)
        }
        if joinRejected(code: code, output: raw) {
            return (raw.isEmpty ? "[!] could not join \(name)" : raw, code == 0 ? 1 : code)
        }
        return ("", 0)
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

    /// The header stores the flag as a private `BOOL` ivar and publishes no
    /// accessor. Missing ivar returns nil so the caller does not guess.
    private static func boolIvar(_ object: AnyObject, name: String) -> Bool? {
        guard let ivar = class_getInstanceVariable(type(of: object), name) else { return nil }
        let pointer = Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar))
        return pointer.load(as: UInt8.self) != 0
    }
}
