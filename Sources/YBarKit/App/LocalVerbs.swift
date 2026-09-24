import AppKit
import Foundation

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
            if let bundle = AppBundle.enclosingBundle(of: executable) {
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

    /// The recorded name, or nil when nothing is selected. A name is one
    /// directory entry under a root, never a path: a hand-edited state file
    /// saying `../..` or `a/b` reads as no selection. The one rule for the
    /// CLI and the daemon's discovery alike.
    public static func currentName(home: URL) -> String? {
        guard let text = try? String(contentsOf: stateFile(home: home), encoding: .utf8) else {
            return nil
        }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\")
        else { return nil }
        return name
    }

    /// The selected theme's entry file; nil when nothing is selected or the
    /// name went stale (theme deleted), so ordinary discovery applies.
    public static func currentEntry(home: URL, roots: [URL]) -> URL? {
        guard let name = currentName(home: home) else { return nil }
        return collect(roots: roots).first { $0.name == name }?.entry
    }
}

enum ThemeVerbs {
    static let usage = "theme list|current|use <name>|reset|install <git-url>"

    /// A wrong invocation exits 2 like every other local verb's; a failed
    /// operation exits 1.
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
            guard args.count >= 2 else { return LocalVerbs.usage("\(instanceName) theme use <name>") }
            return use(args[1], instanceName: instanceName)
        case "install":
            guard args.count >= 2 else {
                return LocalVerbs.usage("\(instanceName) theme install <git-url>")
            }
            return install(args[1])
        default:
            return LocalVerbs.usage("\(instanceName) \(usage)")
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
                no themes found. Set YBAR_THEME_ROOTS=<dir of themes> and run \
                `ybar theme list`; from a source checkout, `scripts/ybar-theme list` \
                sets the checkout's examples/ root for you.
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

        // No daemon: hand it to `start`, which kickstarts a loaded login job
        // rather than standing an unmanaged bar beside it, and otherwise
        // launches YBar.app with the bundle's TCC identity. With no `-c` the
        // daemon's own discovery picks the recorded name up — the same
        // resolution the next login uses — so `-c` is kept only for what that
        // discovery cannot reach: a renamed instance (it never reads
        // current-theme) and a theme that is on the search path only through
        // YBAR_THEME_ROOTS, which neither launchd nor LaunchServices passes on.
        let discoverable = daemonWouldResolve(name, to: match.entry, instanceName: instanceName)
        let arguments = startArguments(
            entry: match.entry, instanceName: instanceName, discoverable: discoverable)
        if instanceName == "ybar", !discoverable {
            FileHandle.standardError.write(Data("""
                note: \(name) is outside the daemon's theme search path, so it is passed \
                with -c for this run only; a login job will not pick it up. Copy it under \
                ~/.config/ybar/themes to make the selection stick.

                """.utf8))
        }
        let started = LocalVerbs.run(arguments: arguments, instanceName: instanceName) ?? 1
        guard started == 0 else {
            FileHandle.standardError.write(
                Data("note: theme \(name) was recorded but could not be started\n".utf8))
            return started
        }
        print("theme: \(name)")
        return started
    }

    /// Pure: the `start` invocation for a recorded theme. `-c` only when the
    /// daemon's own discovery would not land on the same entry.
    static func startArguments(entry: URL, instanceName: String, discoverable: Bool) -> [String] {
        instanceName == "ybar" && discoverable ? ["start"] : ["start", "-c", entry.path]
    }

    /// Whether a daemon started without `-c` would resolve `name` to `entry`.
    /// The daemon's roots are this binary's minus YBAR_THEME_ROOTS — the one
    /// variable a source checkout's shim sets and a launched daemon lacks.
    static func daemonWouldResolve(_ name: String, to entry: URL, instanceName: String) -> Bool {
        var environment = ProcessInfo.processInfo.environment
        environment["YBAR_THEME_ROOTS"] = nil
        guard let resolution = ConfigLocator.resolve(
            explicitPath: nil, instanceName: instanceName, environment: environment, home: home)
        else { return false }
        return resolution.theme == name && resolution.url.path == entry.path
    }

    static func install(_ gitURL: String) -> Int32 {
        let themes = home.appendingPathComponent(".config/ybar/themes")
        try? FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        var name = URL(fileURLWithPath: gitURL).lastPathComponent
        if name.hasSuffix(".git") { name.removeLast(4) }
        let target = themes.appendingPathComponent(name)
        let clone = Spawn.run("/usr/bin/git", ["clone", "--depth", "1", gitURL, target.path])
        guard clone.succeeded else {
            let detail = clone.output.isEmpty ? "" : ": \(clone.output)"
            return fail("[!] git clone failed for \(gitURL)\(detail)")
        }
        if !clone.output.isEmpty { print(clone.output) }
        if ThemeCatalog.entry(in: target) == nil {
            FileHandle.standardError.write(Data("warning: no ybarrc.lua found in \(name)\n".utf8))
        }
        print("installed \(name) — activate with: ybar theme use \(name)")
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        let line = message.hasPrefix("[!]") ? message : "[!] \(message)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        return 1
    }
}

// MARK: - App bundle discovery

/// Where this binary lives, and whether that is inside YBar.app. TCC identity
/// belongs to the bundle — prompts and grants attribute to com.ybar.YBar only
/// when the daemon runs from Contents/MacOS — so anything that starts a
/// daemon on the user's behalf must know the difference.
public enum AppBundle {
    public static let bundleName = "YBar.app"

    /// realpath of the running binary: Homebrew's bin/ybar is a symlink into
    /// the keg, and launchd/open need the real location.
    public static func executableURL() -> URL {
        let raw = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return raw.resolvingSymlinksInPath()
    }

    /// `<bundle>/Contents/MacOS/<tool>` -> `<bundle>`; nil for a bare build
    /// product. All three components are checked rather than just the `.app`
    /// suffix, so a directory a user happened to name `notes.app` cannot be
    /// mistaken for a bundle.
    public static func enclosingBundle(of executable: URL) -> URL? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app"
        else { return nil }
        return bundle
    }

    /// Homebrew installs into `<prefix>/Cellar/ybar/<version>/YBar.app` and
    /// points `<prefix>/opt/ybar` at the current version. A login job naming the
    /// Cellar path dies on the next `brew upgrade`; the opt path survives it,
    /// which is why the formula's own caveats hand users the opt path.
    public static func stablePath(for url: URL, fileManager: FileManager = .default) -> URL {
        var parts = url.pathComponents
        guard let cellar = parts.firstIndex(of: "Cellar"), cellar + 2 < parts.count else {
            return url
        }
        let formula = parts[cellar + 1]
        parts.replaceSubrange(cellar...(cellar + 2), with: ["opt", formula])
        var rebuilt = URL(fileURLWithPath: "/")
        for part in parts.dropFirst() { rebuilt.appendPathComponent(part) }
        return fileManager.fileExists(atPath: rebuilt.path) ? rebuilt : url
    }

    /// Search order, most specific first: the bundle we are running from, then
    /// the two `make app` destinations, then Homebrew — `$HOMEBREW_PREFIX` when
    /// `brew shellenv` exported it, else both documented defaults (Apple silicon
    /// and Intel). `brew --prefix` is never shelled out for: it costs a few
    /// hundred milliseconds, and `brew` is frequently absent from the bare PATH
    /// a launchd job inherits.
    public static func candidates(
        home: URL, executable: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates: [URL] = []
        if let inside = enclosingBundle(of: executable) {
            candidates.append(stablePath(for: inside, fileManager: fileManager))
        }
        candidates.append(
            home.appendingPathComponent("Applications").appendingPathComponent(bundleName))
        candidates.append(URL(fileURLWithPath: "/Applications/\(bundleName)"))
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let exported = environment["HOMEBREW_PREFIX"], !exported.isEmpty {
            prefixes.insert(exported, at: 0)
        }
        for prefix in prefixes {
            candidates.append(URL(fileURLWithPath: "\(prefix)/opt/ybar/\(bundleName)"))
        }
        return candidates
    }

    /// A candidate only counts if it really is a bundle. A bare directory named
    /// `YBar.app` would otherwise be handed to `open`, which refuses it with a
    /// LaunchServices diagnostic instead of a useful one.
    public static func isBundle(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }

    public static func locate(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let known = candidates(home: home, executable: executableURL(),
                               environment: environment, fileManager: fileManager)
            .first { isBundle($0, fileManager: fileManager) }
        if let known { return known }
        // Only once none of the known layouts matched: LaunchServices knows
        // where a copy installed somewhere unusual lives, but only after it has
        // been registered, and this is the expensive lookup.
        guard let registered = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: LaunchAgent.bundleIdentifier)
        else { return nil }
        return isBundle(registered, fileManager: fileManager) ? registered : nil
    }

    /// The binary an instance runs as. The instance name is the binary's
    /// basename (sketchybar's rename-for-a-second-bar trick), so a prepared
    /// second instance carries its own binary inside the bundle; the default one
    /// is plain `ybar`.
    public static func daemonBinary(in bundle: URL, instanceName: String,
                                    fileManager: FileManager = .default) -> URL? {
        let url = bundle.appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(instanceName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - LaunchAgent

/// The login job. launchd loads every plist in `~/Library/LaunchAgents` at login
/// by itself, so writing the file is what makes autostart automatic; the
/// `launchctl` calls only make it take effect without logging out again.
public enum LaunchAgent {
    /// The bundle every instance runs out of, whatever the instance is called.
    public static let bundleIdentifier = "com.ybar.YBar"

    /// The default instance keeps the label docs/INSTALL.md and the bundle
    /// identifier already used, so a hand-installed agent is adopted rather than
    /// duplicated. A renamed instance gets its own label, so two bars can
    /// autostart side by side.
    public static func label(instanceName: String) -> String {
        instanceName == "ybar" ? bundleIdentifier : "com.ybar.\(instanceName)"
    }

    /// launchd and every tool around it expect the filename to be the label.
    public static func plistURL(instanceName: String, home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label(instanceName: instanceName)).plist")
    }

    /// Only stderr is captured. A failure at login is otherwise completely
    /// invisible — the bar simply never appears — and the daemon writes its
    /// diagnostics there. stdout is deliberately left to /dev/null: a config
    /// with a `print()` on a 1 Hz routine would grow an unrotated file forever.
    public static func logURL(instanceName: String, home: URL) -> URL {
        home.appendingPathComponent("Library/Logs")
            .appendingPathComponent("\(instanceName).log")
    }

    /// launchd's per-job minimum spawn interval, in seconds. Read back by
    /// `LocalVerbs.launchdReadyTimeout`: whatever this is, a kickstart has to
    /// outwait it.
    public static let throttleInterval = 30

    /// Booleans have to be real `Bool`s: an `NSNumber(value: 1)` serializes as
    /// `<integer>1</integer>`, which launchd does not read as `RunAtLoad`.
    public static func plist(label: String, programArguments: [String],
                             standardErrorPath: String) -> [String: Any] {
        [
            "Label": label,
            // The real binary inside the bundle, never `open`: launchd has to
            // own the process it supervises, and `open` exits immediately, which
            // reads as a job that finished successfully and is never restarted.
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            // Restart after a crash, but respect a deliberate `ybar stop`:
            // `--exit` terminates the daemon with status 0, which this rule
            // reads as "it meant to go". Plain `KeepAlive: true` would make
            // quitting impossible without a bootout.
            "KeepAlive": ["SuccessfulExit": false],
            // Unclassified jobs get light CPU and I/O throttling. A bar
            // repainting a clock every second is user-facing and would be
            // visibly janky under it.
            "ProcessType": "Interactive",
            // The default already, but it documents that this job needs a real
            // GUI session — and it makes a background-domain bootstrap fail
            // loudly instead of producing a daemon with no WindowServer.
            "LimitLoadToSessionType": "Aqua",
            // What makes System Settings' Login Items row read "YBar" instead of
            // a raw label, and what Apple names as the fix when a launchd job is
            // not attributed to its app. Always the bundle id, never the
            // per-instance label.
            "AssociatedBundleIdentifiers": [bundleIdentifier],
            // Raised from the default 10. A boot failure the daemon cannot
            // recover from — no Metal device, an unreadable config — exits 1,
            // and KeepAlive reads every non-zero code as "restart it", so this
            // interval is the only thing between a broken login and a respawn
            // storm on exactly the machines least able to cope.
            "ThrottleInterval": throttleInterval,
            "StandardErrorPath": standardErrorPath,
        ]
        // Deliberately absent: EnvironmentVariables. A launchd agent inherits a
        // bare PATH, but ScriptRunner.augmentedPATH already prepends the
        // daemon's own directory and both Homebrew prefixes to what every
        // script it spawns receives.
    }

    /// argv for the job. With no config there is no `-c` at all — that absence
    /// is what lets a login job follow `current-theme` across logins instead of
    /// pinning whatever was selected on the day autostart was enabled.
    public static func programArguments(binary: URL, config: String?) -> [String] {
        var arguments = [binary.path]
        if let config {
            arguments.append(contentsOf: ["-c", LocalVerbs.absolutePath(config)])
        }
        return arguments
    }

    public static func xmlData(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Reads a plist back for `autostart status`, so what is reported is what is
    /// on disk rather than what this code would have written.
    public static func read(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    /// The `-c <path>` a job was written with, if any.
    public static func configArgument(in plist: [String: Any]) -> String? {
        guard let program = plist["ProgramArguments"] as? [String],
              let flag = program.firstIndex(where: { $0 == "-c" || $0 == "--config" }),
              flag + 1 < program.count
        else { return nil }
        return program[flag + 1]
    }

    /// Where the job's stderr goes, when the plist says. A hand-written agent
    /// can name any path, and a verb that points at "the log" has to mean
    /// that one, not the one `enable` would have chosen.
    public static func standardErrorPath(in plist: [String: Any]) -> String? {
        guard let path = plist["StandardErrorPath"] as? String, !path.isEmpty else { return nil }
        return path
    }

    /// What a plist's `KeepAlive` does after the daemon exits 0 — the exit
    /// `--exit` produces, and the one `stop` relies on to stick.
    public enum KeepAlivePolicy: Equatable {
        /// Absent or `false`: launchd never respawns it.
        case never
        /// `SuccessfulExit = false` (what `enable` writes) or `Crashed = true`:
        /// back after a crash, left alone after a clean exit.
        case onFailure
        /// `true`, or any condition a clean exit satisfies: back after ANY
        /// exit, so only booting the job out keeps it down.
        case always
    }

    /// launchd ORs the keys of a KeepAlive dictionary, so a clean exit sticks
    /// only when every condition listed is one a clean exit fails:
    /// `SuccessfulExit = false` and `Crashed = true`. Everything else — `true`
    /// (the shape a hand-rolled plist usually has), `SuccessfulExit = true`,
    /// `Crashed = false`, a `PathState`/`NetworkState`/`OtherJob*` condition,
    /// an empty dictionary — reads as "comes back", the safe way to be wrong.
    public static func keepAlivePolicy(in plist: [String: Any]) -> KeepAlivePolicy {
        guard let keepAlive = plist["KeepAlive"] else { return .never }
        switch keepAlive {
        case let flag as Bool:
            return flag ? .always : .never
        case let conditions as [String: Any]:
            guard !conditions.isEmpty else { return .always }
            let staysDown = conditions.allSatisfy { key, value in
                (key == "SuccessfulExit" && value as? Bool == false)
                    || (key == "Crashed" && value as? Bool == true)
            }
            return staysDown ? .onFailure : .always
        default:
            return .always
        }
    }
}

// MARK: - Subprocesses

/// Blocking spawn for the two helpers these verbs need, `launchctl` and `open`.
/// Absolute paths, no shell: nothing here is ever quoted, so a config path with
/// spaces in it crosses untouched as one argv element.
enum Spawn {
    struct Result {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    /// stdout and stderr are folded together because every caller here only ever
    /// echoes them back to the user verbatim. Reading to EOF and only then
    /// waiting is the deadlock-free order.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1,
                          output: "could not run \(executable): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: process.terminationStatus, output: text)
    }
}

// MARK: - launchctl

/// A thin `launchctl` front end. Only the modern domain-target subcommands are
/// used: `load`/`unload` are deprecated and, in the `gui` domain, fail in ways
/// that read like success.
enum Launchctl {
    /// What `launchctl print` says about a label.
    enum JobState: Equatable {
        case loaded       // registered in the domain, running or not
        case notLoaded
        case noDomain     // no GUI login session for this uid: ssh, or sudo
        case unknown(Int32)
    }

    /// `gui/<uid>`, the Aqua login session — never `user/<uid>`, the background
    /// domain, which refuses a job that needs a WindowServer connection.
    static var domain: String { "gui/\(getuid())" }

    static func target(_ label: String) -> String { "\(domain)/\(label)" }

    @discardableResult
    static func run(_ arguments: [String]) -> Spawn.Result {
        Spawn.run("/bin/launchctl", arguments)
    }

    /// What `launchctl print` said about a label, and the process it named.
    struct Job: Equatable {
        let state: JobState
        /// The process launchd is supervising right now. nil for a loaded job
        /// that is down, and for anything that is not loaded — which is why
        /// "loaded" alone never means "running".
        let pid: pid_t?
    }

    /// launchctl exits with the errno-style number itself and prints its
    /// diagnostic to stderr. `print`'s own output is not officially
    /// structured; the exit code decides the state, and the one line read
    /// from the text is the pid, because the code cannot tell a loaded job
    /// that is down from one whose process is alive and wedged.
    static func inspect(_ label: String) -> Job {
        let printed = run(["print", target(label)])
        let state = classify(printStatus: printed.status)
        return Job(state: state, pid: state == .loaded ? pid(inPrintOutput: printed.output) : nil)
    }

    static func state(of label: String) -> JobState {
        inspect(label).state
    }

    /// A loaded job prints `pid = N` while its process is alive and no such
    /// line while it is down. Anchored to a whole trimmed line, so `pid-local
    /// endpoints = {` and the nested blocks cannot match, and a parse miss
    /// only costs the -k that would have replaced a wedged process.
    static func pid(inPrintOutput output: String) -> pid_t? {
        let prefix = "pid = "
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let digits = trimmed.dropFirst(prefix.count)
            guard digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let pid = pid_t(String(digits)), pid > 0
            else { continue }
            return pid
        }
        return nil
    }

    static func classify(printStatus: Int32) -> JobState {
        switch printStatus {
        case 0: return .loaded
        case 113: return .notLoaded
        case 112: return .noDomain
        default: return .unknown(printStatus)
        }
    }

    /// A persistent disable override lives in launchd's own database, survives
    /// deleting and reinstalling the plist, survives reboots, and does NOT show
    /// up in `print`'s exit code — an unloaded job is 113 either way. It is the
    /// one thing here worth parsing text for: there is no exit-code channel, and
    /// a parse miss only costs a note. Modern launchctl prints `=> true`, older
    /// builds `=> disabled`.
    static func isDisabled(label: String) -> Bool {
        let listing = run(["print-disabled", domain])
        guard listing.succeeded else { return false }
        return listing.output.split(separator: "\n").contains { line in
            line.contains("\"\(label)\"")
                && (line.contains("=> true") || line.contains("=> disabled"))
        }
    }

    /// Codes that mean "already in the state you asked for", which an idempotent
    /// verb has to read as success.
    ///   bootstrap 37 EALREADY — the job is already loaded.
    ///   bootout    3 ESRCH — nothing of that name; 36 EINPROGRESS — a teardown
    ///              is already under way and the job does go; 113 — not in this
    ///              domain.
    /// Bootstrap's 5 is deliberately NOT here: it is launchd's catch-all for a
    /// bad path, bad permissions, an unparseable plist or a rejected signature,
    /// and says nothing on its own.
    static func bootstrapSucceeded(_ status: Int32) -> Bool { status == 0 || status == 37 }

    static func bootoutSucceeded(_ status: Int32) -> Bool {
        status == 0 || status == 3 || status == 36 || status == 113
    }

    /// `brew services` installs an agent of its own under its own label. Two
    /// agents with RunAtLoad race for the same socket at login, and the loser
    /// exits 0 — which looks to launchd like a job that meant to quit, so it
    /// never comes back. Worth reporting rather than leaving to be discovered.
    /// `sh.brew.*` is the current spelling, `homebrew.mxcl.*` the legacy one.
    static func homebrewServiceLabel(formula: String) -> String? {
        ["sh.brew.\(formula)", "homebrew.mxcl.\(formula)"].first { state(of: $0) == .loaded }
    }
}

// MARK: - Verbs

/// The optional `-c <path>` these verbs accept. Kept as a value rather than an
/// optional String so "no config given" and "a malformed option" stay distinct:
/// the second has to print usage and exit 2.
public enum ConfigArgument: Equatable {
    case absent
    case path(String)
    case malformed

    public static func parse(_ arguments: [String]) -> ConfigArgument {
        if arguments.isEmpty { return .absent }
        guard arguments.count == 2, arguments[0] == "-c" || arguments[0] == "--config" else {
            return .malformed
        }
        return .path(arguments[1])
    }

    public var value: String? {
        if case .path(let path) = self { return path }
        return nil
    }
}

/// What an argv vector means. Parsing is kept separate from doing, so the argv
/// tests can cover every spelling without ever being one typo away from
/// launching a real bar or writing a real login agent.
public enum Verb: Equatable {
    case start(ConfigArgument)
    case stop
    case restart(ConfigArgument)
    case status
    case autostartEnable(ConfigArgument)
    case autostartDisable
    case autostartStatus
    /// The invocation was wrong; the payload is what to print after the
    /// instance name.
    case usage(String)
}

public enum LocalVerbs {
    public static let verbs: Set<String> = ["start", "stop", "restart", "status", "autostart"]

    /// Pure: what these arguments mean, or nil when they are not ours and the
    /// caller should fall through to the message grammar. Touches nothing.
    public static func parse(_ arguments: [String]) -> Verb? {
        guard let verb = arguments.first, verbs.contains(verb) else { return nil }
        let rest = Array(arguments.dropFirst())

        switch verb {
        case "start":
            let config = ConfigArgument.parse(rest)
            return config == .malformed ? .usage("start [-c <path>]") : .start(config)

        case "stop":
            return rest.isEmpty ? .stop : .usage("stop")

        case "restart":
            let config = ConfigArgument.parse(rest)
            return config == .malformed ? .usage("restart [-c <path>]") : .restart(config)

        case "status":
            return rest.isEmpty ? .status : .usage("status")

        case "autostart":
            // Bare `autostart` reads as `autostart status`, matching
            // the theme namespace's bare-word default: never destructive.
            let action = rest.first ?? "status"
            let tail = Array(rest.dropFirst())
            switch action {
            case "enable":
                let config = ConfigArgument.parse(tail)
                return config == .malformed
                    ? .usage("autostart enable [-c <path>]")
                    : .autostartEnable(config)
            case "disable" where tail.isEmpty:
                return .autostartDisable
            case "status" where tail.isEmpty:
                return .autostartStatus
            default:
                return .usage("autostart enable|disable|status")
            }

        default:
            return nil
        }
    }

    /// Runs process-control verbs first, then the local theme namespace.
    /// Unknown arguments return nil so the caller can use the message grammar.
    public static func run(arguments: [String], instanceName: String) -> Int32? {
        guard let verb = parse(arguments) else {
            guard arguments.first == "theme" else { return nil }
            return ThemeVerbs.run(
                Array(arguments.dropFirst()), instanceName: instanceName)
        }
        switch verb {
        case .usage(let invocation):
            return usage("\(instanceName) \(invocation)")
        case .start(let config):
            guard rootGuard("start"), configExists(config) else { return 1 }
            return start(configOverride: config.value, instanceName: instanceName)
        case .stop:
            // Guarded for the same reason as `autostart disable`: the socket
            // path is keyed on NSUserName(), which is "root" under sudo, so this
            // would probe /tmp/ybar_root.socket, find nothing, and cheerfully
            // report "not running" while the user's bar stayed exactly where it
            // was.
            guard rootGuard("stop") else { return 1 }
            return stop(instanceName: instanceName)
        case .restart(let config):
            guard rootGuard("restart"), configExists(config) else { return 1 }
            return restart(configOverride: config.value, instanceName: instanceName)
        case .status:
            return status(instanceName: instanceName)
        case .autostartEnable(let config):
            guard rootGuard("autostart enable"), configExists(config) else { return 1 }
            return autostartEnable(configOverride: config.value, instanceName: instanceName)
        case .autostartDisable:
            // Guarded too: under sudo this would look at root's LaunchAgents,
            // find nothing, and cheerfully report "already disabled" while the
            // user's own agent stayed exactly where it was.
            guard rootGuard("autostart disable") else { return 1 }
            return autostartDisable(instanceName: instanceName)
        case .autostartStatus:
            return autostartStatus(instanceName: instanceName)
        }
    }

    /// A `-c` the user typed is an assertion about a file, and a missing one is
    /// caught nowhere downstream: ConfigLocator returns nil for an explicit path
    /// that is not there, and the daemon logs one line and keeps running with
    /// the socket already bound — so the readiness poll reports success and the
    /// bar comes up empty. `autostart enable` would freeze that into every
    /// login. Only paths the user typed are checked; `autostart disable` puts
    /// the bar back on the job's own recorded config, and a config deleted since
    /// then must not cost it the bar.
    static func configExists(_ config: ConfigArgument) -> Bool {
        guard let path = config.value else { return true }
        let absolute = absolutePath(path)
        guard FileManager.default.fileExists(atPath: absolute) else {
            _ = fail("config not found: \(absolute)")
            return false
        }
        return true
    }

    /// launchd never rotates what it captures, and one failing Lua callback
    /// writes a line per tick into this file forever under a login job nobody is
    /// watching. Two files of about a megabyte is the cheapest bound that needs
    /// no daemon.
    static func rotateLog(at url: URL, fileManager: FileManager = .default) {
        let limit = 1024 * 1024
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > limit
        else { return }
        let rolled = url.appendingPathExtension("1")
        try? fileManager.removeItem(at: rolled)
        try? fileManager.moveItem(at: url, to: rolled)
    }

    /// Without `-c` the login job starts on whatever discovery finds, so there
    /// has to be something to find. `-c` is also the only route for a source
    /// checkout: its themes resolve through YBAR_THEME_ROOTS, which a launchd
    /// job does not inherit. The refusal to print, or nil when there is
    /// something to start.
    static func nothingToStart(
        instanceName: String, home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard ConfigLocator.locate(explicitPath: nil, instanceName: instanceName,
                                   environment: environment, home: home) == nil
        else { return nil }
        return "nothing to start with: no config under ~/.config/\(instanceName) and no theme "
            + "selected. Pin one: `\(instanceName) autostart enable -c <config>` — the route for "
            + "a source checkout. Or select a theme first, then re-run: "
            + "`\(instanceName) theme use <name>`"
    }

    /// Under sudo these would write a root-owned plist into root's LaunchAgents
    /// and target `gui/0`, which has no login session: the classic install that
    /// reports success and then never starts anything.
    static func rootGuard(_ verb: String) -> Bool {
        guard getuid() == 0 else { return true }
        _ = fail("\(verb) must run as the logged-in user, not root — "
            + "the bar needs your GUI session")
        return false
    }

    // MARK: start

    /// `preferLaunchd: false` is for the caller that has just booted this job
    /// out. bootout is asynchronous: the job can still print as loaded for a
    /// moment after the bar has stopped answering, and a kickstart in that
    /// window resurrects the job that was just removed.
    static func start(configOverride: String?, instanceName: String,
                      preferLaunchd: Bool = true) -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        let label = LaunchAgent.label(instanceName: instanceName)
        let logURL = LaunchAgent.logURL(instanceName: instanceName, home: home)
        let plistURL = LaunchAgent.plistURL(instanceName: instanceName, home: home)

        if SocketClient.isListening(socketPath: socketPath) {
            // Saying "already running" and dropping the config would be the same
            // silent-wrong-config failure `open` has when it reactivates an
            // instance and discards everything after --args.
            guard configOverride == nil else {
                return fail("\(instanceName) is already running — use "
                    + "`\(instanceName) restart -c <path>` to start it with a different config")
            }
            print("\(instanceName) is already running")
            return 0
        }

        // When launchd owns this bar, start it through launchd. Otherwise a
        // `stop` followed by a `start` leaves an unmanaged orphan running
        // alongside a loaded-but-down login job.
        let job = preferLaunchd
            ? Launchctl.inspect(label)
            : Launchctl.Job(state: .notLoaded, pid: nil)
        if let pid = job.pid, configOverride != nil {
            // The probe above said nothing answers, and launchd says the
            // job's process is alive: `open` would put a second bar beside
            // it. A kickstart cannot carry -c, so this is restart's job.
            return fail("\(instanceName) is running (pid \(pid)) under the login job \(label) "
                + "but not answering — `\(instanceName) restart` replaces it")
        }
        if preferLaunchd, configOverride == nil {
            // The log the job writes, which a hand-written plist can put
            // anywhere; the messages and the roll below have to mean that one.
            let jobLog = jobLogURL(plistURL: plistURL, fallback: logURL)
            switch job.state {
            case .loaded:
                let kick: Spawn.Result
                if let pid = job.pid {
                    // Alive under launchd and not answering — the probe above
                    // ruled out a healthy bar. A plain kickstart on a running
                    // service is a no-op that exits 0; only -k swaps the
                    // process out. SIGKILL, so no teardown: acceptable for a
                    // bar that never bound its socket.
                    note("\(instanceName) is running (pid \(pid)) but not answering — replacing it")
                    kick = Launchctl.run(["kickstart", "-k", Launchctl.target(label)])
                } else {
                    // Down, so nothing holds the file: the moment to roll it.
                    rotateLog(at: jobLog)
                    kick = Launchctl.run(["kickstart", Launchctl.target(label)])
                }
                switch kick.status {
                case 0:
                    if let failure = awaitKickstartedJob(
                        label: label, socketPath: socketPath, forced: job.pid != nil, log: jobLog) {
                        return fail(failure)
                    }
                    print("\(instanceName) started (launchd job \(label))")
                    return 0
                case 3, 113:
                    break  // the job went away between the probe and the kickstart
                default:
                    return fail("launchctl kickstart failed (\(kick.status)): \(kick.output)")
                }

            case .notLoaded where FileManager.default.fileExists(atPath: plistURL.path):
                // A plist with no job behind it: `stop` booted it out because
                // its KeepAlive would have put the bar straight back, or
                // someone ran bootout by hand. Loading it again is what "start
                // brings it back" means; an unmanaged bar beside a plist that
                // the next login loads would be a second bar then. A
                // persistent disable override (Login Items, off) is the one
                // case that must stay unmanaged: the user turned the job off.
                if Launchctl.isDisabled(label: label) {
                    note("the login job \(label) is switched off in launchd (Login Items) — "
                        + "starting \(instanceName) unmanaged")
                    break
                }
                rotateLog(at: jobLog)
                let bootstrap = Launchctl.run(["bootstrap", Launchctl.domain, plistURL.path])
                guard Launchctl.bootstrapSucceeded(bootstrap.status) else {
                    note("the login job could not be loaded (launchctl bootstrap "
                        + "\(bootstrap.status): \(bootstrap.output)) — starting \(instanceName) "
                        + "unmanaged; `\(instanceName) autostart enable` rewrites the job")
                    break
                }
                if let failure = awaitKickstartedJob(
                    label: label, socketPath: socketPath, forced: false, log: jobLog) {
                    return fail(failure)
                }
                print("\(instanceName) started (launchd job \(label), loaded from \(plistURL.path))")
                return 0

            default:
                break
            }
        }

        // Only while the bar is confirmed down so no process holds the file,
        // and only on this route: the job's own log was rolled above.
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateLog(at: logURL)

        // Only the `open` route below is instance-blind: LaunchServices execs the
        // bundle's CFBundleExecutable, so a renamed bar would come up as `ybar`
        // on `ybar`'s socket. The launchd kickstart above re-execs the job's own
        // ProgramArguments and is correct for every instance, so it is tried
        // first and this guard sits after it.
        guard instanceName == "ybar" else {
            return fail("start launches \(AppBundle.bundleName), which LaunchServices always "
                + "runs as the default `ybar` instance — run \(instanceName) from its own "
                + "binary inside the bundle, or let launchd own it with "
                + "`\(instanceName) autostart enable -c <path>` (a kickstart cannot carry a "
                + "config, so bake one in)")
        }

        guard let bundle = AppBundle.locate(home: home) else { return failBundleMissing() }

        // The socket file is deliberately never removed here: SocketServer
        // already unlinks a confirmed-dead socket before binding, and unlinking
        // from the client can delete a live daemon's endpoint and brick its IPC
        // for good.
        // -n forces a fresh exec. Without it LaunchServices does not exec at
        // all: it reactivates the instance it still believes is running,
        // SILENTLY DROPS everything after --args, and exits 0 anyway. The ping
        // above is what makes -n safe — nothing is answering, so there is
        // nothing to duplicate.
        // --stderr gives a start that dies immediately the same evidence an
        // autostart failure leaves. --args must come last: everything after it
        // is handed to main() unparsed, and an argument starting with `-` placed
        // before it would be read as an open(1) flag.
        var arguments = ["-n", "-g", "--stderr", logURL.path, bundle.path]
        if let configOverride {
            arguments.append(contentsOf: ["--args", "-c", absolutePath(configOverride)])
        }
        let opened = Spawn.run("/usr/bin/open", arguments)
        guard opened.succeeded else {
            // open's exit code means only "the launch request was accepted"; it
            // never reflects the app's health.
            return fail("could not launch \(bundle.path): \(opened.output)")
        }
        guard waitForDaemon(socketPath: socketPath) else {
            return fail("\(bundle.path) was launched but did not answer within "
                + "\(Int(readyTimeout)) s — see \(logURL.path), or run "
                + "\(bundle.path)/Contents/MacOS/\(instanceName) in a terminal to see why")
        }
        print("\(instanceName) started (\(bundle.path))")
        if let configOverride {
            print(field("config", absolutePath(configOverride)))
        }
        return 0
    }

    // MARK: stop

    static func stop(instanceName: String) -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        let label = LaunchAgent.label(instanceName: instanceName)
        let job = Launchctl.inspect(label)
        let plistURL = LaunchAgent.plistURL(instanceName: instanceName, home: home)
        // A job whose plist is gone stays registered until logout but does NOT
        // come back at the next login. Promising otherwise would point the user
        // at a verb they have already run.
        let hasPlist = FileManager.default.fileExists(atPath: plistURL.path)
        // What the loaded job does after a clean exit is in its plist, not in
        // launchctl's exit code. `enable` writes KeepAlive.SuccessfulExit=false,
        // which lets `--exit` stick; a hand-rolled `<key>KeepAlive</key><true/>`
        // has launchd put the bar straight back, and the only stop that holds
        // against it is booting the job out. An unreadable plist is read the
        // same way: the wrong guess there costs one bootout, the other a bar
        // that "stopped" and is back within seconds.
        let policy = LaunchAgent.read(at: plistURL).map(LaunchAgent.keepAlivePolicy(in:))
        let respawns = job.state == .loaded && hasPlist && policy != .onFailure && policy != .never

        /// The line after "stopped": what the next login does.
        func nextLogin() {
            if hasPlist {
                print("autostart is enabled — it will start again at your next login "
                    + "(`\(instanceName) autostart disable` to turn that off)")
            } else if job.state == .loaded {
                print("the login job \(label) is still loaded, but its plist is gone — "
                    + "it will not come back at your next login")
            }
        }

        /// launchd's own stop for a job it supervises: SIGTERM, then SIGKILL
        /// after the job's exit timeout, and no respawn because the job is
        /// gone from the domain. The plist stays, so `start` or the next login
        /// loads it again — said in full, because "stopped" alone would be
        /// read as "and it stays stopped".
        func bootout(reason: String) -> Int32 {
            let result = Launchctl.run(["bootout", Launchctl.target(label)])
            guard Launchctl.bootoutSucceeded(result.status) else {
                return fail("launchctl bootout failed (\(result.status)): \(result.output)")
            }
            let gone = job.pid.map(waitForProcessGone(pid:)) ?? true
            guard gone, waitForDaemonGone(socketPath: socketPath) else {
                return fail("\(instanceName) did not exit within \(Int(stopTimeout)) s of "
                    + "`launchctl bootout \(Launchctl.target(label))`")
            }
            print("\(instanceName) stopped — the login job \(label) was booted out \(reason)")
            if hasPlist {
                print("its plist stays in place: `\(instanceName) start` or your next login loads "
                    + "the job again (`\(instanceName) autostart disable` removes it)")
            }
            return 0
        }

        guard SocketClient.isListening(socketPath: socketPath) else {
            // The process launchd names is alive but never bound its socket,
            // or lost it: a boot that hung, or a wedge. There is no `--exit`
            // to send it, and a signal would only have launchd respawn it, so
            // the job goes with it.
            if let pid = job.pid {
                print("\(instanceName) is running (pid \(pid)) but not answering on \(socketPath)")
                return bootout(reason: "to stop a process that was not answering")
            }
            print("\(instanceName) is not running")
            // The plist, not the loaded flag, is what decides the next login:
            // launchd loads ~/Library/LaunchAgents by itself. A job that is
            // loaded from a plist that has since gone survives until logout and
            // then does not come back.
            nextLogin()
            return 0
        }

        // The daemon replies and then tears itself down, so a failure to read
        // the reply is not a failure to stop.
        _ = try? SocketClient.send(arguments: ["--exit"], socketPath: socketPath)
        guard waitForDaemonGone(socketPath: socketPath) else {
            // Deliberately no escalation to a signal on an unmanaged bar:
            // there is no pid to send one to, and killing by process-path
            // match is the `pkill -f` bug this verb exists to replace. A
            // supervised one is launchd's to kill.
            guard job.pid != nil else {
                return fail("\(instanceName) did not exit within \(Int(stopTimeout)) s — "
                    + "\(socketPath) still answers")
            }
            return bootout(reason: "to stop a process that ignored --exit")
        }
        // The clean exit above is what the daemon prefers; the bootout is what
        // keeps launchd from undoing it. In between, launchd may already have
        // spawned the next copy, which the bootout then takes down mid-boot —
        // hence the second wait.
        if respawns {
            let result = Launchctl.run(["bootout", Launchctl.target(label)])
            guard Launchctl.bootoutSucceeded(result.status),
                  waitForDaemonGone(socketPath: socketPath)
            else {
                return fail("\(instanceName) exited but its login job \(label) could not be "
                    + "booted out (\(result.status)): \(result.output) — launchd will start it "
                    + "again; `\(instanceName) autostart disable` removes the job")
            }
            let shape = policy == nil
                ? "its plist could not be read"
                : "its plist keeps it alive after any exit"
            print("\(instanceName) stopped — the login job \(label) was booted out too: \(shape)")
            print("its plist stays in place: `\(instanceName) start` or your next login loads "
                + "the job again; `\(instanceName) autostart enable` rewrites it so a plain stop "
                + "holds (`\(instanceName) autostart disable` removes it)")
            return 0
        }
        print("\(instanceName) stopped")
        nextLogin()
        return 0
    }

    // MARK: restart

    static func restart(configOverride: String?, instanceName: String) -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let label = LaunchAgent.label(instanceName: instanceName)
        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        let logURL = LaunchAgent.logURL(instanceName: instanceName, home: home)
        let plistURL = LaunchAgent.plistURL(instanceName: instanceName, home: home)
        let job = Launchctl.inspect(label)
        let state = job.state

        // A launchd-owned bar is restarted through launchd, so the job keeps its
        // identity, its supervision and its log rather than being replaced by an
        // unmanaged copy. A `-c` cannot ride along: kickstart re-executes the
        // job's own ProgramArguments.
        if configOverride == nil, state == .loaded {
            // The log the job writes — a hand-written plist can put it
            // anywhere, and the roll and the messages have to mean that one.
            let jobLog = jobLogURL(plistURL: plistURL, fallback: logURL)
            let kick: Spawn.Result
            var forced = false
            if SocketClient.isListening(socketPath: socketPath) {
                _ = try? SocketClient.send(arguments: ["--exit"], socketPath: socketPath)
                if waitForDaemonGone(socketPath: socketPath) {
                    // It went of its own accord, so no kill is needed — and with
                    // the process gone nothing holds the log open, so this is
                    // the moment to roll it.
                    rotateLog(at: jobLog)
                    kick = Launchctl.run(["kickstart", Launchctl.target(label)])
                } else {
                    // It is still holding the job slot, and a plain kickstart on
                    // a service that is already running is a no-op that exits 0 —
                    // the bar would never be replaced and the wait would time
                    // out on a lie. -k is what actually replaces it. It is
                    // reported everywhere to be SIGKILL, so the daemon skips its
                    // Metal and Lua teardown; acceptable only here, for a bar
                    // that ignored a clean request to quit.
                    forced = true
                    kick = Launchctl.run(["kickstart", "-k", Launchctl.target(label)])
                }
            } else if let pid = job.pid {
                // Alive as far as launchd is concerned, silent on the socket:
                // a boot that hung, or a wedge. Same no-op trap as above, and
                // the same answer.
                note("\(instanceName) is running (pid \(pid)) but not answering — replacing it")
                forced = true
                kick = Launchctl.run(["kickstart", "-k", Launchctl.target(label)])
            } else {
                // Nothing is listening and launchd names no process, so the
                // job is loaded but down, nothing holds the log, and a plain
                // kickstart simply starts it.
                rotateLog(at: jobLog)
                kick = Launchctl.run(["kickstart", Launchctl.target(label)])
            }

            switch kick.status {
            case 0:
                if let failure = awaitKickstartedJob(
                    label: label, socketPath: socketPath, forced: forced, log: jobLog) {
                    return fail(failure)
                }
                print("\(instanceName) restarted (launchd job \(label))")
                return 0
            case 3, 113:
                break  // the job vanished; fall through to stop + start
            default:
                let message = "launchctl kickstart failed (\(kick.status)): \(kick.output)"
                guard SocketClient.isListening(socketPath: socketPath) else {
                    // The `--exit` above already took the bar down, and a clean
                    // exit is exactly what KeepAlive.SuccessfulExit=false reads
                    // as "it meant to go", so nothing brings it back on its own.
                    // Falling through to `start` would re-run this same kickstart
                    // and fail the same way, so name the route that works.
                    return fail(message + " — \(instanceName) is now stopped and launchd "
                        + "will not restart it. `\(instanceName) autostart disable` then "
                        + "`\(instanceName) start` puts a bar back.")
                }
                return fail(message)
            }
        }

        if configOverride != nil, state == .loaded,
           let plist = LaunchAgent.read(at: plistURL),
           let program = plist["ProgramArguments"] as? [String] {
            print("note: the login job runs \(program.joined(separator: " ")) — "
                + "-c applies to this run only")
        }

        let stopped = stop(instanceName: instanceName)
        guard stopped == 0 else { return stopped }
        return start(configOverride: configOverride, instanceName: instanceName)
    }

    // MARK: status

    static func status(instanceName: String) -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        let running = SocketClient.isListening(socketPath: socketPath)
        let bundle = AppBundle.locate(home: home)
        // Discovery names the theme only when the recorded name actually
        // produced the path — a deleted theme, or one run straight out of a
        // clone off the search path (docs/THEMES.md), gets no label.
        let resolution = ConfigLocator.resolve(
            explicitPath: nil, instanceName: instanceName, home: home)
        let config = resolution?.url
        let label = LaunchAgent.label(instanceName: instanceName)
        let plistURL = LaunchAgent.plistURL(instanceName: instanceName, home: home)
        let hasPlist = FileManager.default.fileExists(atPath: plistURL.path)
        let plist = hasPlist ? LaunchAgent.read(at: plistURL) : nil
        let policy = plist.map(LaunchAgent.keepAlivePolicy(in:))
        let job = Launchctl.inspect(label)
        let state = job.state
        let brew = instanceName == "ybar" ? Launchctl.homebrewServiceLabel(formula: "ybar") : nil

        // First, not last: everything below describes root's session, not the
        // user's — root's home, root's socket, root's gui/0 domain.
        if getuid() == 0 {
            print("note: running as root — this is root's session (uid 0), not yours.")
        }
        // launchd's pid is the third answer: a process that is alive and not
        // answering is neither "running" nor "not running", and calling it the
        // latter sends the user to `start`, which then finds the slot taken.
        let liveness: String
        if running {
            liveness = "running"
        } else if let pid = job.pid {
            liveness = "running (pid \(pid)) but not answering on the socket"
        } else {
            liveness = "not running"
        }
        print(field(instanceName, liveness))
        print(field("instance", instanceName))
        print(field("socket", socketPath))
        print(field("bundle", bundle?.path ?? "not found"))
        var configLine = config?.path ?? "none found"
        if let theme = resolution?.theme { configLine += " (theme: \(theme))" }
        print(field("config", configLine))
        print(field("autostart", autostartSummary(
            label: label, hasPlist: hasPlist, state: state, policy: policy)))
        if let plist, let log = LaunchAgent.standardErrorPath(in: plist) {
            print(field("log", log))
        }

        // `config` is what a fresh start would pick. The daemon does not report
        // its own config over the wire yet, so a running bar may be on another.
        if running {
            print("note: `config` is what a fresh start would pick; "
                + "a running bar may have been started with -c.")
        }
        if !running, job.pid != nil {
            print("note: `\(instanceName) restart` replaces it (launchctl kickstart -k "
                + "\(Launchctl.target(label))); `\(instanceName) stop` boots the job out.")
        }
        if policy == .always {
            print("note: the plist's KeepAlive brings the bar back after any exit, so "
                + "`\(instanceName) stop` boots the job out; `\(instanceName) autostart enable` "
                + "rewrites it so a plain stop holds.")
        }
        if let brew {
            print("note: Homebrew also manages a login job (\(brew)) — two jobs will fight over "
                + "\(socketPath). Run `brew services stop ybar`.")
        }
        if state == .noDomain {
            print("note: launchctl reports no GUI session for uid \(getuid()) — "
                + "autostart state is unknown from here (ssh or sudo).")
        } else if Launchctl.isDisabled(label: label) {
            print("note: launchd holds a persistent disable override for \(label), so the job "
                + "will not start whatever its plist says. `\(instanceName) autostart enable` "
                + "clears it.")
        }
        if config == nil {
            print("note: no config found; the bar will come up empty. See docs/INSTALL.md.")
        }
        return 0
    }

    // MARK: autostart

    static func autostartEnable(configOverride: String?, instanceName: String) -> Int32 {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        guard let bundle = AppBundle.locate(home: home) else { return failBundleMissing() }
        guard let binary = AppBundle.daemonBinary(in: bundle, instanceName: instanceName) else {
            return fail("\(bundle.path) has no Contents/MacOS/\(instanceName) — "
                + "a renamed instance needs its own binary inside the bundle")
        }
        if instanceName == "ybar", let brew = Launchctl.homebrewServiceLabel(formula: "ybar") {
            return fail("Homebrew already manages a ybar login job (\(brew)) — "
                + "run `brew services stop ybar` first")
        }

        let label = LaunchAgent.label(instanceName: instanceName)
        let plistURL = LaunchAgent.plistURL(instanceName: instanceName, home: home)
        let logURL = LaunchAgent.logURL(instanceName: instanceName, home: home)
        let socketPath = WireFormat.socketPath(instanceName: instanceName)

        // Checked before the bar is touched: from ssh or sudo there is no GUI
        // domain, every launchctl call below fails anyway, and stopping the
        // user's bar to discover that would be pure damage.
        guard Launchctl.state(of: label) != .noDomain else {
            return fail("launchctl reports no GUI session for uid \(getuid()) — autostart "
                + "has to be enabled from a normal login session, not ssh or sudo")
        }

        // Also before the bar is touched: a refusal leaves the screen as it was.
        if configOverride == nil,
           let message = nothingToStart(instanceName: instanceName, home: home) {
            return fail(message)
        }

        // Hand a running bar over BEFORE anything is written, so a bar that will
        // not stop leaves no half-installed job behind. The handover itself is
        // mandatory: launchd's copy would find the socket taken, exit 0 on
        // purpose, and KeepAlive.SuccessfulExit=false would never retry it —
        // leaving the job loaded but permanently down.
        var handedOver = false
        if SocketClient.isListening(socketPath: socketPath) {
            _ = try? SocketClient.send(arguments: ["--exit"], socketPath: socketPath)
            guard waitForDaemonGone(socketPath: socketPath) else {
                return fail("a \(instanceName) is running and would not stop — "
                    + "run `\(instanceName) stop` and try again")
            }
            handedOver = true
        }

        // From here on the user's bar is already down. This verb is about LOGIN
        // behavior; failing it must not also leave the screen without a bar —
        // the same rule `autostart disable` follows. Put the bar back when the
        // job is definitively not coming up, and say so plainly when it cannot
        // be put back from here (a renamed instance, which LaunchServices
        // cannot start at all).
        func failAfterHandover(_ message: String) -> Int32 {
            guard handedOver, !SocketClient.isListening(socketPath: socketPath) else {
                return fail(message)
            }
            let stopped = "\n    \(instanceName) is stopped — "
                + "bring it back with `\(instanceName) start`"
            // A loaded job is NOT a bar on its way back. The handover above sent
            // `--exit`, the daemon answered it with status 0, and
            // KeepAlive.SuccessfulExit=false reads that as "it meant to go" —
            // so nothing respawns it. The two failure paths that reach here
            // before the bootout leave exactly that state, so kickstart the job
            // that is actually loaded rather than standing an unmanaged copy
            // beside it. It is also the only route that works for a renamed
            // instance, which LaunchServices cannot start at all.
            if Launchctl.state(of: label) == .loaded {
                let kick = Launchctl.run(["kickstart", Launchctl.target(label)])
                // 3 and 113 mean the job vanished between the probe and the
                // kickstart — the same codes start and restart fall through on.
                // Anything else has had its chance: racing an unmanaged `open`
                // against a job that may still be coming up would put two bars
                // on the screen.
                if kick.status != 3, kick.status != 113 {
                    guard kick.succeeded,
                          waitForDaemon(socketPath: socketPath, timeout: launchdReadyTimeout,
                                        noticeAfter: readyTimeout,
                                        waitingNotice: launchdWaitingNotice)
                    else { return fail(message + stopped) }
                    return fail(message + "\n    autostart was not enabled, but the bar is "
                        + "back under the login job that was already loaded")
                }
            }
            if instanceName == "ybar",
               start(configOverride: configOverride, instanceName: instanceName) == 0 {
                return fail(message + "\n    autostart was not enabled, "
                    + "but the bar has been restarted unmanaged")
            }
            return fail(message + stopped)
        }

        // launchd expands no `~` and inherits no working directory, so only an
        // absolute path survives login.
        let programArguments = LaunchAgent.programArguments(
            binary: binary, config: configOverride)
        let contents = LaunchAgent.plist(
            label: label, programArguments: programArguments, standardErrorPath: logURL.path)
        // A failed enable must not take away the autostart the user already had,
        // so keep the old bytes for the rollback below. nil when there was no
        // file, which is also how `restorePlist` knows to remove ours instead.
        let previousPlist = try? Data(contentsOf: plistURL)
        do {
            // Neither directory is guaranteed: ~/Library/LaunchAgents does not
            // exist on a fresh account, and launchd creates the log FILE but not
            // its directory — a missing one makes the job fail to spawn.
            try fileManager.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            rotateLog(at: logURL, fileManager: fileManager)
            try LaunchAgent.xmlData(contents).write(to: plistURL, options: .atomic)
        } catch {
            return failAfterHandover(
                "could not write \(plistURL.path): \(error.localizedDescription)")
        }
        // Not optional: an atomic write goes through a temp file whose mode
        // follows the process umask, and launchd silently skips an agent plist
        // whose permissions it dislikes — then rejects the bootstrap with an
        // opaque 5. Same idiom as SocketServer's chmod on the socket.
        chmod(plistURL.path, 0o644)

        // Deleting the plist is only right when this call is what created it.
        // Otherwise put back what was there: a plist in ~/Library/LaunchAgents
        // loads at the next login whatever bootstrap said today, so throwing the
        // user's working one away would silently turn off autostart they already
        // had. Returns the sentence to append, so the failure message says what
        // is actually on disk now.
        func restorePlist() -> String {
            guard let previousPlist else {
                try? fileManager.removeItem(at: plistURL)
                return " No login job was left behind."
            }
            try? previousPlist.write(to: plistURL, options: .atomic)
            chmod(plistURL.path, 0o644)
            return " Your previous login job has been put back."
        }

        // Clears any persistent disable override, which is the only thing that
        // does: a label someone once ran `launchctl disable` on stays refused by
        // bootstrap afterwards, with a "Load failed: 5" that names nothing.
        // Fire and forget — it is idempotent and cheap, and the one failure it
        // has (no such domain) was already ruled out above.
        Launchctl.run(["enable", Launchctl.target(label)])

        // By label, never by path: the label form needs nothing on disk. A job
        // left from an earlier enable would otherwise make bootstrap fail.
        let bootout = Launchctl.run(["bootout", Launchctl.target(label)])
        guard Launchctl.bootoutSucceeded(bootout.status) else {
            return failAfterHandover(
                "launchctl bootout failed (\(bootout.status)): \(bootout.output)."
                + restorePlist())
        }

        let bootstrap = Launchctl.run(["bootstrap", Launchctl.domain, plistURL.path])
        if !Launchctl.bootstrapSucceeded(bootstrap.status) {
            switch bootstrap.status {
            case 112:
                // The file is left in place deliberately: launchd loads
                // ~/Library/LaunchAgents at login by itself.
                return failAfterHandover(
                    "launchctl could not find domain \(Launchctl.domain) — autostart "
                    + "needs a GUI login session, not ssh or sudo. The plist was written, so "
                    + "it will still take effect at your next login.")
            case 134:
                return failAfterHandover("launchd refused the job for this session type — "
                    + "run this from a normal login session." + restorePlist())
            case 5:
                return failAfterHandover("launchctl bootstrap failed (5), launchd's catch-all. "
                    + "Check \(plistURL.path)'s permissions and the program path, then: "
                    + "log show --last 2m --predicate 'process == \"launchd\"'."
                    + restorePlist())
            default:
                return failAfterHandover(
                    "launchctl bootstrap failed (\(bootstrap.status)): \(bootstrap.output)."
                    + restorePlist())
            }
        }

        // 5 is overloaded and bootout is asynchronous, so assert the end state
        // rather than trusting the codes.
        guard Launchctl.state(of: label) == .loaded else {
            return failAfterHandover("bootstrap reported success but the job is not loaded — "
                + "log show --last 2m --predicate 'process == \"launchd\"'."
                + restorePlist())
        }

        print("autostart enabled")
        print(field("job", label))
        print(field("plist", plistURL.path))
        print(field("program", programArguments.joined(separator: " ")))
        print(field("log", logURL.path))
        if !waitForDaemon(socketPath: socketPath) {
            // A warning, not an error: autostart is enabled, which is what was
            // asked for.
            print("the job is loaded but the bar has not answered yet — check \(logURL.path)")
        }
        print("Turn it off again with `\(instanceName) autostart disable`.")
        return 0
    }

    static func autostartDisable(instanceName: String) -> Int32 {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let label = LaunchAgent.label(instanceName: instanceName)
        let plistURL = LaunchAgent.plistURL(instanceName: instanceName, home: home)
        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        let wasRunning = SocketClient.isListening(socketPath: socketPath)
        let state = Launchctl.state(of: label)
        let hasPlist = fileManager.fileExists(atPath: plistURL.path)
        // Read the job's config before the plist goes, so the bar that is put
        // back below is the same bar, not whatever discovery would pick.
        let jobConfig = LaunchAgent.read(at: plistURL).flatMap(LaunchAgent.configArgument(in:))

        if !hasPlist, state != .loaded {
            print("autostart is already disabled")
            return 0
        }
        if state == .loaded {
            let bootout = Launchctl.run(["bootout", Launchctl.target(label)])
            guard Launchctl.bootoutSucceeded(bootout.status) else {
                return fail("launchctl bootout failed (\(bootout.status)): \(bootout.output)")
            }
            // bootout returns as soon as launchd has signalled the job, not when
            // the process is gone — without this wait the relaunch below would
            // see a socket that is about to disappear and skip itself.
            if wasRunning { _ = waitForDaemonGone(socketPath: socketPath) }
        }
        if hasPlist {
            do {
                try fileManager.removeItem(at: plistURL)
            } catch {
                return fail("could not remove \(plistURL.path): \(error.localizedDescription)")
            }
        }
        // Never `launchctl disable`: it writes a persistent override that
        // survives deleting and reinstalling the plist, after which bootstrap
        // refuses the job with an error that names nothing.

        print("autostart disabled")
        // Booting the job out also stopped the bar. The user asked for it not to
        // start at LOGIN, not to lose the bar in front of them.
        if wasRunning, instanceName == "ybar", !SocketClient.isListening(socketPath: socketPath) {
            if start(configOverride: jobConfig, instanceName: instanceName,
                     preferLaunchd: false) == 0 {
                print("(\(instanceName) is still running, no longer managed by launchd)")
            } else {
                let note = "note: the bar did not come back up — "
                    + "start it with `\(instanceName) start`\n"
                FileHandle.standardError.write(Data(note.utf8))
            }
        }
        // Disabling succeeded either way: turning autostart off must not both
        // take the bar away and report a failure.
        return 0
    }

    static func autostartStatus(instanceName: String) -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let label = LaunchAgent.label(instanceName: instanceName)
        let plistURL = LaunchAgent.plistURL(instanceName: instanceName, home: home)
        let hasPlist = FileManager.default.fileExists(atPath: plistURL.path)
        let state = Launchctl.state(of: label)
        let plist = hasPlist ? LaunchAgent.read(at: plistURL) : nil
        let policy = plist.map(LaunchAgent.keepAlivePolicy(in:))

        // First, like `status`: everything below describes root's LaunchAgents
        // and root's gui/0 domain, not the user's.
        if getuid() == 0 {
            print("note: running as root — this is root's session (uid 0), not yours.")
        }
        print("autostart: " + autostartSummary(
            label: label, hasPlist: hasPlist, state: state, policy: policy))
        if instanceName == "ybar", let brew = Launchctl.homebrewServiceLabel(formula: "ybar") {
            print("note: Homebrew also manages a login job (\(brew)) — "
                + "run `brew services stop ybar` unless that is the one you want.")
        }
        if state != .noDomain, Launchctl.isDisabled(label: label) {
            print("note: launchd holds a persistent disable override for \(label), so the job "
                + "will not start whatever this file says. `\(instanceName) autostart enable` "
                + "clears it.")
        }
        guard hasPlist else { return 0 }
        print(field("plist", plistURL.path))
        // Reported from the file rather than from what this code would write, so
        // a hand-edited plist shows its own contents.
        guard let plist else {
            print(field("plist", "unreadable — rewrite it with `\(instanceName) autostart enable`"))
            return 0
        }
        if let program = plist["ProgramArguments"] as? [String] {
            print(field("program", program.joined(separator: " ")))
        }
        if let log = LaunchAgent.standardErrorPath(in: plist) {
            print(field("log", log))
        }
        if LaunchAgent.configArgument(in: plist) != nil {
            print("the job pins that config — `ybar theme use` will not change "
                + "what starts at login.")
        }
        switch policy {
        case .always:
            print("KeepAlive brings the bar back after any exit, so `\(instanceName) stop` "
                + "boots the job out; `\(instanceName) autostart enable` rewrites the plist "
                + "so a plain stop holds.")
        case .never:
            print("no KeepAlive: the bar is not restarted after a crash "
                + "(`\(instanceName) autostart enable` rewrites the plist).")
        default:
            break
        }
        return 0
    }

    /// `policy` is the plist's KeepAlive when there is a readable plist; the
    /// shape `enable` writes says nothing extra, the other two are named,
    /// because they change what `stop` and a crash do.
    static func autostartSummary(label: String, hasPlist: Bool,
                                 state: Launchctl.JobState,
                                 policy: LaunchAgent.KeepAlivePolicy? = nil) -> String {
        if state == .noDomain {
            return "unknown — launchctl reports no GUI session for uid \(getuid()) "
                + "(run this from a normal login session)"
        }
        // "disabled" would read identically to a machine that simply has no
        // agent, which is the opaque-failure trap this verb exists to avoid.
        if case .unknown(let code) = state {
            return "unknown — `launchctl print \(Launchctl.target(label))` exited \(code)"
        }
        let shape: String
        switch policy {
        case .always: shape = ", KeepAlive: always"
        case .never: shape = ", KeepAlive: off"
        default: shape = ""
        }
        switch (hasPlist, state == .loaded) {
        case (true, true): return "enabled (job \(label) loaded\(shape))"
        case (true, false): return "enabled (job \(label) starts at your next login\(shape))"
        // A job loaded from a plist that is now gone survives until logout.
        case (false, true): return "disabled (job \(label) is still loaded until you log out)"
        case (false, false): return "disabled"
        }
    }

    // MARK: Helpers

    /// A cold first run is dyld, AppKit, Metal device creation, runtime shader
    /// compilation and the Lua config — 1-3 s normally, and capable of spiking
    /// well past 5 s on a cold filesystem cache with a fresh ad-hoc signature to
    /// validate.
    static let readyTimeout: TimeInterval = 15
    /// Anything launchd mediates has to outwait the job's own ThrottleInterval:
    /// `kickstart` is a trigger like any other, and one issued inside that
    /// window is accepted, exits 0, and then queues. A shorter wait would report
    /// a failure for a bar that is doing nothing wrong.
    static let launchdReadyTimeout =
        TimeInterval(LaunchAgent.throttleInterval) + readyTimeout
    static let launchdWaitingNotice =
        "still waiting — launchd throttles restarts to one every "
        + "\(LaunchAgent.throttleInterval) s...\n"
    static let noticeAfter: TimeInterval = 2
    static let stopTimeout: TimeInterval = 5
    static let pollInterval: TimeInterval = 0.1

    /// launchd expands no `~` and inherits no working directory, so a config
    /// path only survives login once it is absolute.
    public static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Readiness, not existence: this is the one place `ping` is the right
    /// question, because "answers commands" is exactly what is being waited for.
    static func waitForDaemon(
        socketPath: String,
        timeout: TimeInterval = LocalVerbs.readyTimeout,
        noticeAfter: TimeInterval = LocalVerbs.noticeAfter,
        waitingNotice: String = "still waiting for the bar to come up...\n"
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let notice = Date().addingTimeInterval(noticeAfter)
        var noticed = false
        while Date() < deadline {
            if SocketClient.ping(socketPath: socketPath) { return true }
            if !noticed, Date() >= notice {
                noticed = true
                // stderr, so a script capturing stdout is unaffected.
                FileHandle.standardError.write(Data(waitingNotice.utf8))
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return SocketClient.ping(socketPath: socketPath)
    }

    /// The wait after a kickstart launchd accepted. launchd will not respawn a
    /// job more often than its ThrottleInterval, and a kickstart inside that
    /// window is accepted and then queued — waiting less than the throttle
    /// would report a failure for a bar doing nothing wrong, and point at a
    /// log with nothing in it. When the bar still has not answered after that
    /// and the kick was a plain one, one `kickstart -k` follows: a process
    /// that came up and hung before binding the socket is alive as far as
    /// launchd is concerned, and only -k replaces it. `forced` says the first
    /// kick was already -k, so there is nothing further to try. Returns the
    /// failure to print, or nil once the bar answers.
    static func awaitKickstartedJob(label: String, socketPath: String,
                                    forced: Bool, log: URL) -> String? {
        let target = Launchctl.target(label)
        var forced = forced
        if waitForDaemon(socketPath: socketPath, timeout: launchdReadyTimeout,
                         noticeAfter: readyTimeout, waitingNotice: launchdWaitingNotice) {
            return nil
        }
        if !forced {
            note("no answer after \(Int(launchdReadyTimeout)) s — retrying with "
                + "launchctl kickstart -k \(target)")
            let kick = Launchctl.run(["kickstart", "-k", target])
            forced = kick.succeeded
            if forced, waitForDaemon(socketPath: socketPath, timeout: launchdReadyTimeout,
                                     noticeAfter: readyTimeout,
                                     waitingNotice: launchdWaitingNotice) {
                return nil
            }
        }
        return "the login job \(label) was kickstarted\(forced ? " with -k" : "") but the bar "
            + "did not answer within \(Int(launchdReadyTimeout)) s — see \(log.path); "
            + "`launchctl kickstart -k \(target)` is the manual equivalent"
    }

    /// The log a loaded job actually writes, from its plist; `fallback` (the
    /// path `enable` chooses) when the plist is unreadable or names none.
    static func jobLogURL(plistURL: URL, fallback: URL) -> URL {
        guard let plist = LaunchAgent.read(at: plistURL),
              let path = LaunchAgent.standardErrorPath(in: plist)
        else { return fallback }
        return URL(fileURLWithPath: path)
    }

    /// For a job launchd is tearing down: bootout returns once the job has
    /// been signalled, and the pid launchd printed is what says when the
    /// process has actually gone. `kill(pid, 0)` asks without signalling;
    /// ESRCH is the answer wanted.
    static func waitForProcessGone(pid: pid_t) -> Bool {
        func gone() -> Bool { kill(pid, 0) != 0 && errno == ESRCH }
        let deadline = Date().addingTimeInterval(stopTimeout)
        while Date() < deadline {
            if gone() { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return gone()
    }

    /// Polls the socket FILE, not a connect. A daemon that exits unlinks its
    /// endpoint, so the file going away is the signal — and every probe connect
    /// parks a connection on the listener's accept queue until it is accepted,
    /// which does not happen while the main thread is busy. Probing on every
    /// tick would fill that queue and flip connect() to ECONNREFUSED, so the
    /// wait would answer "gone" about a bar that is very much alive. One connect
    /// at the deadline still catches a daemon that died without unlinking.
    static func waitForDaemonGone(socketPath: String) -> Bool {
        let deadline = Date().addingTimeInterval(stopTimeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: socketPath) { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return !SocketClient.isListening(socketPath: socketPath)
    }

    static func field(_ name: String, _ value: String) -> String {
        let width = max(name.count + 1, 11)
        return "  \(name.padding(toLength: width, withPad: " ", startingAt: 0))\(value)"
    }

    /// The invocation was wrong. Exit 2, the one distinction a shell wrapper
    /// acts on.
    @discardableResult
    static func usage(_ invocation: String) -> Int32 {
        FileHandle.standardError.write(Data("[!] usage: \(invocation)\n".utf8))
        return 2
    }

    /// The operation failed. Exit 1.
    @discardableResult
    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("[!] \(message)\n".utf8))
        return 1
    }

    /// Progress and asides go to stderr, so a script capturing stdout only
    /// ever sees the verb's answer.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("note: \(message)\n".utf8))
    }

    static func failBundleMissing() -> Int32 {
        fail("\(AppBundle.bundleName) not found — build it with `make app`, "
            + "or install it with `brew install ybar`")
    }
}
