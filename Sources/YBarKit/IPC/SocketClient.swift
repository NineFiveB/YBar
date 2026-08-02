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

    /// Probe whether a daemon is alive behind the socket.
    public static func ping(socketPath: String) -> Bool {
        (try? send(arguments: ["--ping"], socketPath: socketPath, timeout: 1.0)) != nil
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
            print("ybar \(Version.current)")
            return 0
        case "--config", "-c":
            // `ybar -c <path>` boots the daemon with an explicit config.
            return nil
        default:
            break
        }

        // `-m/--message` is accepted for sketchybar muscle-memory; it is implicit otherwise.
        var argv = arguments
        if argv.first == "-m" || argv.first == "--message" {
            argv.removeFirst()
        }

        // AeroSpace hook fast path: `exec-on-workspace-change` exports its
        // payload as environment variables. Folding them into the trigger here
        // lets the hook invoke ybar directly — no shell wrapper needed for
        // `$AEROSPACE_FOCUSED_WORKSPACE` interpolation (one fewer process
        // spawn on every workspace switch).
        if argv.first == "--trigger",
           !argv.contains(where: { $0.hasPrefix("FOCUSED_WORKSPACE=") }),
           let focused = ProcessInfo.processInfo.environment["AEROSPACE_FOCUSED_WORKSPACE"] {
            argv.append("FOCUSED_WORKSPACE=\(focused)")
            if let previous = ProcessInfo.processInfo.environment["AEROSPACE_PREV_WORKSPACE"] {
                argv.append("PREV_WORKSPACE=\(previous)")
            }
        }

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

    static let helpText = """
    ybar — a Metal-rendered, scriptable status bar for macOS.

    Usage:
      ybar                          start the daemon
      ybar -c <path>                start the daemon with an explicit config script
      ybar <domain>...              send commands to the running daemon, e.g.:

      ybar --bar height=32 color=0xcc1e1e2e
      ybar --add item clock right
      ybar --set clock label="12:00" icon=sf:clock label.color=0xffffffff
      ybar --subscribe clock system_woke
      ybar --animate tanh 30 --set clock label.color=0xffff0000
      ybar --query bar

    See docs/ARCHITECTURE.md for the full command grammar.
    """
}

public enum Version {
    public static let current = "0.1.0"
    /// Instance name is the binary basename: renaming the binary yields an
    /// independent bar instance with its own socket and config (sketchybar behavior).
    public static var instanceName: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    }
}
