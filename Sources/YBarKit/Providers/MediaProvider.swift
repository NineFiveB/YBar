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
    private var terminationToken: NSObjectProtocol?

    /// The whitelisted players, by bundle ID (process checks) and the name
    /// the AppleScript dictionary and MEDIA_APP use.
    nonisolated static let players: [(bundleID: String, app: String)] = [
        ("com.apple.Music", "Music"),
        ("com.spotify.client", "Spotify"),
    ]

    public init() {}

    public func start() {
        guard tokens.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        let sources: [(notification: String, app: String)] = [
            ("com.apple.Music.playerInfo", "Music"),
            ("com.spotify.client.PlaybackStateChanged", "Spotify"),
        ]
        seedFromRunningPlayers()
        // Neither player posts a final playback notification when it QUITS,
        // so the cache would keep the dead track and every reload (hotload
        // runs one per config save) would resurrect the pill from it.
        terminationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier ?? ""
            MainActor.assumeIsolated {
                guard let self,
                      let env = MediaProvider.reduce(termination: bundleID, current: self.current)
                else { return }
                self.current = [:]
                self.onEvent?("media_change", env["MEDIA_STATE"] ?? "", env)
            }
        }
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
        if let terminationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationToken)
        }
        terminationToken = nil
    }

    /// Pure: the env to publish when the process `bundleID` quit, or nil when
    /// the cached state is not that player's (a quitting app that was never
    /// the source must not blank a still-playing one). All five MEDIA_* keys
    /// stay present so consumers see one shape; "stopped" is the state the
    /// players' own scripting dictionaries use, and widgets that only show
    /// on playing/paused hide on it.
    nonisolated static func reduce(termination bundleID: String, current: [String: String]) -> [String: String]? {
        guard let app = players.first(where: { $0.bundleID == bundleID })?.app,
              current["MEDIA_APP"] == app else { return nil }
        return [
            "MEDIA_APP": app,
            "MEDIA_STATE": "stopped",
            "MEDIA_TITLE": "",
            "MEDIA_ARTIST": "",
            "MEDIA_ALBUM": "",
        ]
    }

    /// The notifications only cover playback CHANGES, so a daemon started
    /// mid-song would show nothing until the user next touches the player.
    /// Seed by querying each player that is ALREADY RUNNING (never launches
    /// one — the process check is NSWorkspace, and the script itself only
    /// runs when the app was seen alive). Async; fires onEvent like a real
    /// notification when it finds active playback.
    private func seedFromRunningPlayers() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for player in MediaProvider.players where running.contains(player.bundleID) {
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
