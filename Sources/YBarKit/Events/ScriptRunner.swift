import Foundation

/// Runs plugin scripts: `/usr/bin/env sh -c <script>` with the sketchybar env
/// contract, cwd = config dir, killed after 60 s. Fire-and-forget; scripts
/// respond by calling the CLI back.
public final class ScriptRunner: @unchecked Sendable {
    public var configDirectory: URL
    public var baseEnvironment: [String: String]
    /// Watchdog: a script still running after this long is signalled, and
    /// killed `killGrace` later if it ignored that (tests shorten both).
    var timeout: TimeInterval = 60
    var killGrace: TimeInterval = 2

    public init(configDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                baseEnvironment: [String: String] = [:]) {
        self.configDirectory = configDirectory
        self.baseEnvironment = baseEnvironment
    }

    public func run(script: String, environment: [String: String]) {
        guard !script.isEmpty else { return }
        launch(arguments: ["sh", "-c", script], environment: environment)
    }

    private func launch(arguments: [String], environment: [String: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = configDirectory

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in baseEnvironment { mergedEnvironment[key] = value }
        for (key, value) in environment { mergedEnvironment[key] = value }
        mergedEnvironment["PATH"] = ScriptRunner.augmentedPATH(mergedEnvironment["PATH"])
        process.environment = mergedEnvironment

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("[ybar] failed to run script: \(error)\n".utf8))
            return
        }

        let box = ProcessBox(process: process)
        let killGrace = killGrace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            box.terminateIfRunning(killAfter: killGrace)
        }
    }

    /// Run the config script itself (blocking is not required; config runs async
    /// and configures the daemon through the CLI).
    public func runConfigScript(at url: URL) {
        // Force the executable bit like sketchybar does — a config that was just
        // written from an editor is often missing it.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        // The path travels as an argv word ($0), immune to quotes/spaces/metachars
        // in the path; sh's ENOEXEC fallback still runs shebang-less scripts.
        launch(arguments: ["sh", "-c", "exec \"$0\"", url.path], environment: [:])
    }
}

extension ScriptRunner {
    /// Homebrew/local bins for daemons launched outside a login shell
    /// (aerospace, blueutil, battery ... live there).
    static func augmentedPATH(_ current: String?) -> String {
        // Symlinks resolved so a brew-symlinked launch pins the real keg or
        // bundle directory, which holds only this build's `ybar`.
        let executable = (Bundle.main.executablePath as NSString?)?.resolvingSymlinksInPath
        return augmentedPATH(current, selfDir: (executable as NSString?)?.deletingLastPathComponent)
    }

    static func augmentedPATH(_ current: String?, selfDir: String?) -> String {
        var path = current ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // The daemon's own directory FIRST: plugins call `ybar` back and must
        // reach the running build, not whichever `ybar` the inherited PATH
        // lists earlier (a LaunchAgent that puts /opt/homebrew/bin up front
        // routed every callback to a different install). The inherited order
        // itself is never reshuffled — only a missing entry is added.
        if let selfDir, !path.split(separator: ":").contains(Substring(selfDir)) {
            path = selfDir + ":" + path
        }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"]
        where !path.split(separator: ":").contains(Substring(extra)) {
            path += ":" + extra
        }
        return path
    }
}

/// Watchdog handle for a fire-and-forget child. Process spawns the child as
/// its own process-group leader, so signalling the group reaps `sh -c`
/// pipelines and backgrounded helpers along with the shell; whatever ignores
/// SIGTERM gets SIGKILL after a short grace. Only a helper that setsid()s into
/// its own session escapes (macOS ships no setsid(1); nohup keeps the group).
final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(process: Process) { self.process = process }

    func terminateIfRunning(killAfter grace: TimeInterval = 2) {
        guard process.isRunning else { return }
        signalGroup(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [self] in
            guard process.isRunning else { return }
            signalGroup(SIGKILL)
        }
    }

    /// Only ever signals a group the child leads — never one this daemon
    /// could share — and falls back to the child alone otherwise.
    private func signalGroup(_ signal: Int32) {
        let pid = process.processIdentifier
        if getpgid(pid) == pid, killpg(pid, signal) == 0 { return }
        if signal == SIGKILL { kill(pid, SIGKILL) } else { process.terminate() }
    }
}
