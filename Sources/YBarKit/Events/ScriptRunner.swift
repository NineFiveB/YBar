import Foundation

/// Runs plugin scripts: `/usr/bin/env sh -c <script>` with the sketchybar env
/// contract, cwd = config dir, killed after 60 s. Fire-and-forget; scripts
/// respond by calling the CLI back.
public final class ScriptRunner: @unchecked Sendable {
    public var configDirectory: URL
    public var baseEnvironment: [String: String]

    private static let timeout: TimeInterval = 60

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
        process.environment = mergedEnvironment

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("[ybar] failed to run script: \(error)\n".utf8))
            return
        }

        let box = ProcessBox(process: process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ScriptRunner.timeout) {
            box.terminateIfRunning()
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

final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(process: Process) { self.process = process }
    func terminateIfRunning() {
        if process.isRunning { process.terminate() }
    }
}
