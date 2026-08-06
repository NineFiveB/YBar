import AppKit

/// Now-playing provider: listens for the distributed notifications Music and
/// Spotify post on every playback change — public API, unlike MediaRemote,
/// which macOS 15.4+ gates to entitled processes. Emits `media_change` with
/// MEDIA_APP/MEDIA_STATE/MEDIA_TITLE/MEDIA_ARTIST/MEDIA_ALBUM.
@MainActor
public final class MediaProvider {
    public var onEvent: ((_ name: String, _ info: String, _ env: [String: String]) -> Void)?

    /// Last seen playback env, so late subscribers (config reload) can query.
    public private(set) var current: [String: String] = [:]

    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        guard tokens.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        let sources: [(notification: String, app: String)] = [
            ("com.apple.Music.playerInfo", "Music"),
            ("com.spotify.client.PlaybackStateChanged", "Spotify"),
        ]
        seedFromRunningPlayers()
        for source in sources {
            let token = center.addObserver(
                forName: NSNotification.Name(source.notification),
                object: nil,
                queue: .main
            ) { [weak self] note in
                let info = note.userInfo ?? [:]
                let env: [String: String] = [
                    "MEDIA_APP": source.app,
                    "MEDIA_STATE": ((info["Player State"] as? String) ?? "").lowercased(),
                    "MEDIA_TITLE": (info["Name"] as? String) ?? "",
                    "MEDIA_ARTIST": (info["Artist"] as? String) ?? "",
                    "MEDIA_ALBUM": (info["Album"] as? String) ?? "",
                ]
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.current = env
                    self.onEvent?("media_change", env["MEDIA_STATE"] ?? "", env)
                }
            }
            tokens.append(token)
        }
    }

    public func stop() {
        let center = DistributedNotificationCenter.default()
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }

    /// The notifications only cover playback CHANGES, so a daemon started
    /// mid-song would show nothing until the user next touches the player.
    /// Seed by querying each player that is ALREADY RUNNING (never launches
    /// one — the process check is NSWorkspace, and the script itself only
    /// runs when the app was seen alive). Async; fires onEvent like a real
    /// notification when it finds active playback.
    private func seedFromRunningPlayers() {
        let players: [(bundleID: String, app: String)] = [
            ("com.apple.Music", "Music"),
            ("com.spotify.client", "Spotify"),
        ]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for player in players where running.contains(player.bundleID) {
            // Tab-joined so titles containing "|" or "," survive splitting.
            let script = """
            if application "\(player.app)" is running then
            tell application "\(player.app)"
            set pstate to (player state as text)
            set ptitle to ""
            set partist to ""
            set palbum to ""
            try
            set ptitle to (name of current track as text)
            set partist to (artist of current track as text)
            set palbum to (album of current track as text)
            end try
            return pstate & tab & ptitle & tab & partist & tab & palbum
            end tell
            end if
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let fields = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\t")
                let state = fields.first?.lowercased() ?? ""
                guard state == "playing" || state == "paused" else { return }
                let env: [String: String] = [
                    "MEDIA_APP": player.app,
                    "MEDIA_STATE": state,
                    "MEDIA_TITLE": fields.count > 1 ? fields[1] : "",
                    "MEDIA_ARTIST": fields.count > 2 ? fields[2] : "",
                    "MEDIA_ALBUM": fields.count > 3 ? fields[3] : "",
                ]
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        guard let self else { return }
                        // A real notification may have landed while the seed
                        // was in flight — never clobber fresher state.
                        guard self.current.isEmpty else { return }
                        self.current = env
                        self.onEvent?("media_change", state, env)
                    }
                }
            }
        }
    }
}
