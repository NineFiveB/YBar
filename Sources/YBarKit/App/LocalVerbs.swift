import Foundation

/// The verbs that never reach the socket — `ybar theme …` and
/// `ybar autostart …`, the Windows port's local_verbs.cpp. main.swift asks
/// here before the CLI client and before the daemon, so they work with no
/// daemon running and can never become one by accident (a bare `ybar theme`
/// used to be swallowed by the socket path and exit 0 silently).
public enum LocalVerbs {
    /// Exit code when `arguments` name a local verb, nil otherwise.
    public static func run(arguments: [String], instanceName: String) -> Int32? {
        guard let verb = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch verb {
        case "theme": return ThemeVerbs.run(rest, instanceName: instanceName)
        case "autostart": return AutostartVerbs.run(rest, instanceName: instanceName)
        default: return nil
        }
    }
}

// MARK: - Themes

/// Where themes live and which one is selected. A theme is any directory
/// carrying an entry-point file; the selection is the theme NAME in
/// `~/.config/ybar/current-theme` (the same file the shell script wrote, so
/// an existing selection carries over), resolved against the roots at every
/// start. ConfigLocator honours it for the default instance.
public enum ThemeCatalog {
    /// The port's order (spec 12).
    public static let entryNames = ["ybarrc.lua", "ybar.jsonc", "ybarrc.jsonc"]

    public static func entry(in directory: URL) -> URL? {
        for name in entryNames {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Search roots, in priority order: `$YBAR_THEME_ROOTS` (colon-separated;
    /// the compatibility shim points it at a checkout's examples/), the
    /// shipped examples beside the executable or one level up (the port's
    /// layout), the Homebrew keg's share/ybar/examples (it sits beside
    /// YBar.app inside the keg), then the user's own ~/.config/ybar/themes.
    public static func roots(
        home: URL, executable: URL?, environment: [String: String]
    ) -> [URL] {
        var roots: [URL] = []
        if let extra = environment["YBAR_THEME_ROOTS"] {
            roots += extra.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        if let executable {
            let directory = executable.deletingLastPathComponent()
            roots.append(directory.appendingPathComponent("examples"))
            roots.append(directory.deletingLastPathComponent().appendingPathComponent("examples"))
            if let bundle = AppBundle.bundleURL(containing: executable) {
                roots.append(bundle.deletingLastPathComponent()
                    .appendingPathComponent("share/ybar/examples"))
            }
        }
        roots.append(home.appendingPathComponent(".config/ybar/themes"))
        return roots
    }

    /// Every theme under the roots, sorted by name. First root wins for a
    /// duplicate name: a user copy shadows nothing, but a name must not list
    /// twice.
    public static func collect(roots: [URL]) -> [(name: String, entry: URL)] {
        let fileManager = FileManager.default
        var themes: [(name: String, entry: URL)] = []
        for root in roots {
            // Names, not URLs: the URL enumerator resolves symlinks in the
            // root (/var → /private/var), and an entry path should read
            // under the root the user configured.
            guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let child = root.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                      isDirectory.boolValue, let entry = entry(in: child)
                else { continue }
                if !themes.contains(where: { $0.name == name }) {
                    themes.append((name, entry))
                }
            }
        }
        return themes.sorted { $0.name < $1.name }
    }

    public static func stateFile(home: URL) -> URL {
        home.appendingPathComponent(".config/ybar/current-theme")
    }

    public static func currentName(home: URL) -> String? {
        guard let text = try? String(contentsOf: stateFile(home: home), encoding: .utf8) else {
            return nil
        }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The selected theme's entry file; nil when nothing is selected or the
    /// name went stale (theme deleted), so ordinary discovery applies.
    public static func currentEntry(home: URL, roots: [URL]) -> URL? {
        guard let name = currentName(home: home) else { return nil }
        return collect(roots: roots).first { $0.name == name }?.entry
    }
}

enum ThemeVerbs {
    static let usage = "[!] usage: ybar theme list|current|use <name>|reset|install <git-url>"

    static func run(_ args: [String], instanceName: String) -> Int32 {
        switch args.first ?? "list" {
        case "list": return list()
        case "current":
            print(ThemeCatalog.currentName(home: home) ?? "no theme selected")
            return 0
        case "reset":
            try? FileManager.default.removeItem(at: ThemeCatalog.stateFile(home: home))
            print("theme selection cleared; the default config discovery applies")
            return 0
        case "use":
            guard args.count >= 2 else { return fail("[!] usage: ybar theme use <name>") }
            return use(args[1], instanceName: instanceName)
        case "install":
            guard args.count >= 2 else { return fail("[!] usage: ybar theme install <git-url>") }
            return install(args[1])
        default:
            return fail(usage)
        }
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var roots: [URL] {
        ThemeCatalog.roots(home: home, executable: AppBundle.executableURL(),
                           environment: ProcessInfo.processInfo.environment)
    }

    static func list() -> Int32 {
        let themes = ThemeCatalog.collect(roots: roots)
        guard !themes.isEmpty else {
            // None of the roots exists — the shape a `make app` bundle has,
            // since the shipped examples/ sit in the checkout, not the
            // bundle. Name the way out rather than leaving the user to find
            // docs/THEMES.md.
            print("""
                no themes found. From a source checkout run `scripts/ybar-theme list`, \
                which adds the checkout's examples/ as a root; \
                otherwise set YBAR_THEME_ROOTS=<dir of themes>.
                """)
            return 0
        }
        let active = ThemeCatalog.currentName(home: home)
        for theme in themes {
            let name = theme.name.padding(toLength: max(24, theme.name.count), withPad: " ", startingAt: 0)
            print("\(theme.name == active ? "*" : " ") \(name) \(theme.entry.path)")
        }
        return 0
    }

    static func use(_ name: String, instanceName: String) -> Int32 {
        guard let match = ThemeCatalog.collect(roots: roots).first(where: { $0.name == name }) else {
            return fail("[!] no theme named \(name) (try `ybar theme list`)")
        }
        let state = ThemeCatalog.stateFile(home: home)
        do {
            try FileManager.default.createDirectory(
                at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (name + "\n").write(to: state, atomically: true, encoding: .utf8)
        } catch {
            return fail("[!] could not write \(state.path): \(error)")
        }

        // A running daemon re-points at the entry file over the socket — the
        // reload path it already has — instead of being killed out from under
        // launchd's KeepAlive, which respawned the OLD config (the wedge the
        // shell script used to cause).
        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        if SocketClient.ping(socketPath: socketPath) {
            do {
                let reply = try SocketClient.send(
                    arguments: ["--reload", match.entry.path], socketPath: socketPath)
                if reply.hasPrefix(WireFormat.errorPrefix) { return fail(reply) }
            } catch {
                return fail("[!] \(error)")
            }
            print("theme: \(name)")
            return 0
        }

        // No daemon: start one, but only from the bundle. A bare swift-build
        // binary takes the terminal's TCC identity and every privacy prompt
        // with it, so it is refused rather than launched.
        let executable = AppBundle.executableURL()
        guard let bundle = AppBundle.bundleURL(containing: executable) else {
            return fail("""
                [!] theme recorded, but not applied: no daemon is running and \(executable.path) \
                is not inside YBar.app, so nothing was launched. Build the bundle (make app, \
                or brew install) and start it — the recorded theme is picked up by config discovery.
                """)
        }
        guard Subprocess.run("/usr/bin/open", ["-g", bundle.path, "--args", "-c", match.entry.path]) == 0
        else { return fail("[!] open failed for \(bundle.path)") }
        print("theme: \(name) (started \(bundle.lastPathComponent))")
        return 0
    }

    static func install(_ gitURL: String) -> Int32 {
        let themes = home.appendingPathComponent(".config/ybar/themes")
        try? FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        var name = URL(fileURLWithPath: gitURL).lastPathComponent
        if name.hasSuffix(".git") { name.removeLast(4) }
        let target = themes.appendingPathComponent(name)
        guard Subprocess.run("/usr/bin/git", ["clone", "--depth", "1", gitURL, target.path]) == 0 else {
            return fail("[!] git clone failed for \(gitURL)")
        }
        if ThemeCatalog.entry(in: target) == nil {
            FileHandle.standardError.write(Data("warning: no ybarrc.lua found in \(name)\n".utf8))
        }
        print("installed \(name) — activate with: ybar theme use \(name)")
        return 0
    }
}

// MARK: - Autostart

/// The LaunchAgent `ybar autostart` manages: com.ybar.YBar in
/// ~/Library/LaunchAgents, the same shape docs/INSTALL.md had users hand-edit.
public enum LaunchAgent {
    public static let label = "com.ybar.YBar"

    public static func plistURL(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Pure: the agent definition. KeepAlive.SuccessfulExit=false restarts
    /// after a crash but respects a deliberate `ybar --exit`. `-c` appears
    /// only when a config was pinned explicitly — with it omitted, discovery
    /// (current-theme first, then the ordinary search) applies on every
    /// respawn, which is what makes `ybar theme use` stick across restarts;
    /// the hand-written plist's `-c` used to pull the old theme back.
    public static func plist(binary: String, configPath: String?) -> [String: Any] {
        var arguments = [binary]
        if let configPath { arguments += ["-c", configPath] }
        return [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
    }

    public static func plistData(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

enum AutostartVerbs {
    static let usage = "[!] usage: ybar autostart enable [-c <config>]|disable|status"

    static func run(_ args: [String], instanceName: String) -> Int32 {
        switch args.first ?? "status" {
        case "enable":
            if args.count == 1 { return enable(explicitConfig: nil, instanceName: instanceName) }
            guard args.count == 3, args[1] == "-c" else { return fail(usage) }
            return enable(explicitConfig: args[2], instanceName: instanceName)
        case "disable": return disable()
        case "status": return status()
        default: return fail(usage)
        }
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var domain: String { "gui/\(getuid())" }
    static var service: String { "\(domain)/\(LaunchAgent.label)" }

    static func enable(explicitConfig: String?, instanceName: String) -> Int32 {
        // TCC identity lives in the bundle: launchd must run
        // YBar.app/Contents/MacOS/ybar, never a bare build product.
        let executable = AppBundle.executableURL()
        guard AppBundle.bundleURL(containing: executable) != nil else {
            return fail("""
                [!] \(executable.path) is not inside an app bundle; autostart needs YBar.app for \
                its TCC identity (make app, or brew install, then run that binary)
                """)
        }
        let binary = AppBundle.stablePath(for: executable)

        var configPath: String?
        if let explicitConfig {
            let expanded = (explicitConfig as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                return fail("[!] config not found: \(explicitConfig)")
            }
            configPath = URL(fileURLWithPath: expanded).standardizedFileURL.path
        } else if ConfigLocator.locate(explicitPath: nil, instanceName: instanceName) == nil {
            // `-c` leads: it is the only route that works for a source
            // checkout, whose themes live outside every search root and
            // resolve through YBAR_THEME_ROOTS — which a launchd agent does
            // not inherit, so a name selected there would not survive here.
            return fail("""
                [!] nothing to start with: no config under ~/.config/ybar and no theme selected. \
                Pin one: ybar autostart enable -c <config> — the route for a source checkout. \
                Or select a theme first, then re-run: ybar theme use <name>
                """)
        }

        let url = LaunchAgent.plistURL(home: home)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LaunchAgent.plistData(
                LaunchAgent.plist(binary: binary, configPath: configPath)).write(to: url)
        } catch {
            return fail("[!] could not write \(url.path): \(error)")
        }

        // A daemon started by hand would collide with the agent's: the instance
        // lock makes the loser exit non-zero, which KeepAlive then retries
        // every 10 s. Hand it over instead.
        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        if !isLoaded, SocketClient.ping(socketPath: socketPath) {
            print("handing the running daemon over to launchd")
            _ = try? SocketClient.send(arguments: ["--exit"], socketPath: socketPath)
            var waited = 0
            while waited < 30, SocketClient.ping(socketPath: socketPath) {
                usleep(100_000)
                waited += 1
            }
        }
        // Re-enable is a restart with the new plist; a missing job is fine.
        _ = Subprocess.run("/bin/launchctl", ["bootout", service], quiet: true)
        let status = Subprocess.run("/bin/launchctl", ["bootstrap", domain, url.path])
        guard status == 0 else {
            return fail("[!] launchctl bootstrap failed (\(status)); the plist is at \(url.path)")
        }
        print("autostart enabled: \(binary)\(configPath.map { " -c \($0)" } ?? "")")
        print(configPath == nil
            ? "config: discovered at every start (current-theme, then ~/.config/ybar)"
            : "config: pinned — `ybar theme use` reloads the running bar, but this file wins on restart")
        print("Turn it off with `ybar autostart disable`; restart the bar with "
            + "`launchctl kickstart -k \(service)` (never pkill: KeepAlive respawns it).")
        return 0
    }

    static func disable() -> Int32 {
        let url = LaunchAgent.plistURL(home: home)
        let wasLoaded = isLoaded
        if wasLoaded {
            _ = Subprocess.run("/bin/launchctl", ["bootout", service], quiet: true)
        }
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed { try? FileManager.default.removeItem(at: url) }
        guard wasLoaded || existed else {
            print("autostart already disabled")
            return 0
        }
        print("autostart disabled"
            + (wasLoaded ? " (the supervised daemon was stopped; `open -g YBar.app` starts it unsupervised)" : ""))
        return 0
    }

    static func status() -> Int32 {
        let url = LaunchAgent.plistURL(home: home)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any]
        else {
            print("autostart: disabled")
            return 0
        }
        let arguments = (plist["ProgramArguments"] as? [String]) ?? []
        print("autostart: enabled (\(url.path))")
        print("  program: \(arguments.joined(separator: " "))")
        print("  launchd: \(isLoaded ? "loaded" : "not loaded — launchctl bootstrap \(domain) \(url.path)")")
        return 0
    }

    static var isLoaded: Bool {
        Subprocess.run("/bin/launchctl", ["print", service], quiet: true) == 0
    }
}

// MARK: - Helpers

/// Where this binary lives, and whether that is inside YBar.app. TCC identity
/// belongs to the bundle — prompts and grants attribute to com.ybar.YBar only
/// when the daemon runs from Contents/MacOS — so anything that starts a
/// daemon on the user's behalf must know the difference.
public enum AppBundle {
    /// realpath of the running binary: Homebrew's bin/ybar is a symlink into
    /// the keg, and launchd/open need the real location.
    public static func executableURL() -> URL {
        let raw = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return raw.resolvingSymlinksInPath()
    }

    /// The .app around a Contents/MacOS binary, or nil for a bare one.
    public static func bundleURL(containing executable: URL) -> URL? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app"
        else { return nil }
        return bundle
    }

    /// Pure: `<prefix>/Cellar/ybar/<version>/X` → `<prefix>/opt/ybar/X`. The
    /// opt link survives upgrades; the versioned keg a LaunchAgent would
    /// otherwise pin does not. Nil when the path is not keg-installed.
    public static func homebrewOptPath(for resolved: String) -> String? {
        let parts = resolved.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let cellar = parts.firstIndex(of: "Cellar"), parts.count > cellar + 3,
              parts[cellar + 1] == "ybar"
        else { return nil }
        return (parts[..<cellar] + ["opt", "ybar"] + parts[(cellar + 3)...]).joined(separator: "/")
    }

    /// The path a LaunchAgent should carry for this binary.
    static func stablePath(for executable: URL) -> String {
        if let opt = homebrewOptPath(for: executable.path),
           FileManager.default.fileExists(atPath: opt) {
            return opt
        }
        return executable.path
    }
}

enum Subprocess {
    /// Run to completion with inherited stdio (or none when quiet). The exit
    /// status, or -1 when the launch itself failed.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], quiet: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if quiet {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    return 1
}
