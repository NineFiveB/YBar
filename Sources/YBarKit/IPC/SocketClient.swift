import Foundation

/// Blocking unix-domain-socket client used by the CLI role and by tests.
public enum SocketClient {
    public enum ClientError: Error, CustomStringConvertible {
        case connectionFailed(String)
        case sendFailed
        case receiveFailed

        public var description: String {
            switch self {
            case .connectionFailed(let path):
                return "could not connect to \(path) — is the ybar daemon running?"
            case .sendFailed: return "failed to send message to daemon"
            case .receiveFailed: return "failed to read reply from daemon"
            }
        }
    }

    /// Send argv to the daemon and return its text reply.
    public static func send(arguments: [String], socketPath: String, timeout: TimeInterval = 5.0) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectionFailed(socketPath) }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        _ = withUnsafeBytes(of: &tv) { raw in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, raw.baseAddress, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafeBytes(of: &tv) { raw in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, raw.baseAddress, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClientError.connectionFailed(socketPath)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count)))
            }
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw ClientError.connectionFailed(socketPath) }

        let frame = WireFormat.frame(WireFormat.encode(arguments: arguments))
        guard writeAll(fd: fd, data: frame) else { throw ClientError.sendFailed }

        guard let header = readExactly(fd: fd, count: 4),
              let length = WireFormat.frameLength(header: header)
        else { throw ClientError.receiveFailed }
        guard length > 0 else { return "" }
        guard let payload = readExactly(fd: fd, count: Int(length)) else { throw ClientError.receiveFailed }
        return String(decoding: payload, as: UTF8.self)
    }

    /// Probe whether a daemon ANSWERS COMMANDS. This is a full round trip, and
    /// the reply can only be produced from the daemon's main thread — so a live
    /// bar that is busy (running a cold Lua config, servicing a `--reload`) says
    /// "no" here for seconds at a time. Use it to wait for readiness, never to
    /// decide whether a daemon exists.
    public static func ping(socketPath: String) -> Bool {
        (try? send(arguments: ["--ping"], socketPath: socketPath, timeout: 1.0)) != nil
    }

    /// Probe whether anything is LISTENING on the path, without needing a reply.
    /// The kernel completes the connect from the listen backlog even while the
    /// daemon's main thread is parked, so this separates "a stale socket file"
    /// (connect refused) from "a daemon that is simply busy" — a distinction
    /// `ping` cannot make, and the one that decides whether it is safe to unlink
    /// the file or to launch a second instance.
    public static func isListening(socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Non-blocking: with the accept loop parked and the backlog full,
        // connect() would otherwise block with no timeout to rescue it.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count)))
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        // Darwin completes an AF_UNIX connect synchronously, so these are all
        // but unreachable and are kept only as a non-negative. Note what is NOT
        // here: a full listen backlog is refused with ECONNREFUSED, which is
        // indistinguishable from a stale socket file. So never poll this in a
        // tight loop — each probe parks a connection on the listener until the
        // accept loop takes it, and enough of them manufacture that refusal.
        // (The structural fix is to stop the accept loop blocking on the main
        // thread; a bigger backlog and a file-based wait are what bound it
        // here.)
        return errno == EAGAIN || errno == EINPROGRESS
    }

    static func writeAll(fd: Int32, data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            guard written > 0 else { return false }
            remaining.removeFirst(written)
        }
        return true
    }

    static func readExactly(fd: Int32, count: Int) -> Data? {
        var data = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        while data.count < count {
            let wanted = min(buffer.count, count - data.count)
            let received = read(fd, &buffer, wanted)
            guard received > 0 else { return nil }
            data.append(contentsOf: buffer[0..<received])
        }
        return data
    }
}

/// The CLI role of the ybar binary.
public enum CLIClient {
    /// If the arguments describe a client invocation, execute it and return the exit code.
    /// Returns nil when the invocation should boot the daemon instead.
    public static func runIfClient(arguments: [String]) -> Int32? {
        guard !arguments.isEmpty else { return nil }

        switch arguments[0] {
        case "--help", "-h":
            print(helpText)
            return 0
        case "--version", "-v":
            print("ybar \(Version.display)")
            return 0
        case "--config", "-c":
            // `ybar -c <path>` boots the daemon with an explicit config.
            return nil
        default:
            break
        }

        // Process-control verbs (`start`, `stop`, `restart`, `status`,
        // `autostart`) are bare words that manage the daemon rather than talk
        // to it, so they are answered here, before anything is put on the wire.
        // They are checked ahead of the `-m` strip so that `ybar -m start`
        // still means "send the word start to the daemon".
        if let exit = LocalVerbs.run(arguments: arguments, instanceName: Version.instanceName) {
            return exit
        }

        // `-m/--message` is accepted for sketchybar muscle-memory; it is implicit otherwise.
        var argv = arguments
        if argv.first == "-m" || argv.first == "--message" {
            argv.removeFirst()
        }

        argv = foldTriggerEnvironment(into: argv, environment: ProcessInfo.processInfo.environment)

        let instanceName = Version.instanceName
        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        do {
            let reply = try SocketClient.send(arguments: argv, socketPath: socketPath)
            if reply.hasPrefix(WireFormat.errorPrefix) {
                FileHandle.standardError.write(Data((reply + "\n").utf8))
                return 1
            }
            if !reply.isEmpty {
                print(reply)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("[!] \(error)\n".utf8))
            return 1
        }
    }

    /// Workspace-hook fast path. AeroSpace's `exec-on-workspace-change` and
    /// yabai's signal actions export their payload as environment variables;
    /// folding them into a `--trigger` message here lets the hook invoke ybar
    /// directly, with no shell wrapper for `$AEROSPACE_FOCUSED_WORKSPACE` or
    /// `$YABAI_*` interpolation (one fewer process spawn per workspace
    /// switch). Explicit `KEY=value` tokens always win over the environment;
    /// every other message passes through untouched.
    static func foldTriggerEnvironment(into argv: [String],
                                       environment: [String: String]) -> [String] {
        guard argv.first == "--trigger" else { return argv }
        var argv = argv
        func fold(_ name: String, _ value: String) {
            guard !argv.contains(where: { $0.hasPrefix("\(name)=") }) else { return }
            argv.append("\(name)=\(value)")
        }
        if let focused = environment["AEROSPACE_FOCUSED_WORKSPACE"] {
            fold("FOCUSED_WORKSPACE", focused)
        }
        if let previous = environment["AEROSPACE_PREV_WORKSPACE"] {
            fold("PREV_WORKSPACE", previous)
        }
        // Sorted so the folded tail is deterministic (dictionary order is not).
        for (key, value) in environment.sorted(by: { $0.key < $1.key })
        where key.hasPrefix("YABAI_") {
            fold(String(key.dropFirst("YABAI_".count)), value)
        }
        return argv
    }

    static let helpText = """
    ybar — a Metal-rendered, scriptable status bar for macOS.

    Usage:
      ybar                          run the daemon in this terminal; config is discovered:
                                    selected theme, then ~/.config/ybar/ybarrc.lua,
                                    ybarrc, ybarrc.jsonc, ybar.jsonc, ~/.ybarrc.lua, ~/.ybarrc
      ybar -c <path>                run the daemon with an explicit config
      ybar <domain>...              send commands to the running daemon (below)
      ybar --help | -h              this text
      ybar --version | -v           version, plus the build's commit from an app bundle

    Process control — these drive YBar.app rather than the bare binary, which is
    what keeps privacy prompts attributed to YBar (docs/INSTALL.md):
      ybar start [-c <path>]        launch the bar in the background
      ybar stop                     stop the running bar
      ybar restart [-c <path>]      stop it and launch it again
      ybar status                   bar, config and autostart state

    Local verbs (no daemon needed):
      ybar theme list|current|use <name>|reset|install <git-url>
                                    select a theme; a running bar reloads in place,
                                    otherwise YBar.app is started with it
      ybar autostart enable [-c <config>]|disable|status
                                    manage the com.ybar.YBar LaunchAgent (KeepAlive,
                                    config discovered at each start unless pinned)

    Daemon verbs (sketchybar's grammar; several --domains batch in one message):
      --bar <prop>=<val>...                 --default <prop>=<val>... | reset
      --add item <name> <position>          --add event <name> [notification]
      --add graph|slider <name> <position> <width>
      --add bracket <name> <member>...      --add alias "Owner[,Window]" <position>
      --set <name> <prop>=<val>...          --remove <name>
      --subscribe <name> <event>...         --trigger <event> [KEY=VAL...]
      --animate <curve> <frames>            --update
      --push <graph> <value>...             --query bar|defaults|events|displays|apps|<item>
      --move <name> before|after <anchor>   --reorder <name>...
      --rename <old> <new>                  --clone <new> <source> [before|after]
      --reload [path]                       --hotload on|off
      --volume <0-100|+N|-N>                --app <pid|bundle-id> activate|hide|quit|kill
      --ping                                --exit
      (<name> in --set and --remove may be a /regex/ matching several items)

    Examples:
      ybar --bar height=32 color=0xcc1e1e2e
      ybar --add item clock right
      ybar --set clock label="12:00" icon=sf:clock label.color=0xffffffff
      ybar --subscribe clock system_woke
      ybar --animate tanh 30 --set clock label.color=0xffff0000
      ybar --query bar
      ybar --volume 40                (or +4 / -4 to step the output volume)
      ybar --query apps               running apps: name, bundle_id, pid, active, hidden
      ybar --app com.apple.Safari activate      (or hide | quit | kill; a pid works too)

    Process-control exit codes: 0 success, 1 the operation failed, 2 the
    invocation was wrong. A rejected message is an [!] reply and exits 1.
    `ybar --ping` is the scriptable liveness probe.

    Property keys, events and the Lua API: docs/EXTENDING.md. Install, config and
    themes: README.md. The engine design and the full grammar: docs/ARCHITECTURE.md.
    """
}

public enum Version {
    public static let current = "0.1.0"
    /// The enclosing bundle's CFBundleVersion: the short commit hash that
    /// `make app`, `make release` and a `--HEAD` formula install stamp at
    /// assembly time, or the release build number the committed plist
    /// carries. Nil for a bare executable (`make run`, the test host).
    public static var build: String? {
        guard let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              !value.isEmpty else { return nil }
        return value
    }
    /// What `--version` prints after "ybar ".
    public static var display: String { display(current: current, build: build) }

    /// `0.1.0 (a1b2c3d)` from a bundle, the bare `0.1.0` otherwise, so a bug
    /// report from a dev build names its commit (SECURITY.md asks for either).
    static func display(current: String, build: String?) -> String {
        guard let build else { return current }
        return "\(current) (\(build))"
    }
    /// Instance name is the binary basename: renaming the binary yields an
    /// independent bar instance with its own socket and config (sketchybar behavior).
    public static var instanceName: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    }
}
