import Foundation

/// Unix-domain-socket server for the daemon role. Connections are accepted on a
/// dedicated thread; each request hops synchronously to the main actor (all
/// state mutation is main-thread serialized, sketchybar's model), replies, closes.
public final class SocketServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case alreadyRunning(String)
        case bindFailed(String)

        public var description: String {
            switch self {
            case .alreadyRunning(let path):
                return "another ybar daemon is already running (socket: \(path))"
            case .bindFailed(let path):
                return "could not bind socket at \(path)"
            }
        }
    }

    public let path: String
    private let handler: @MainActor ([String]) -> String
    private var listenFD: Int32 = -1
    private var thread: Thread?

    public init(path: String, handler: @escaping @MainActor ([String]) -> String) {
        self.path = path
        self.handler = handler
    }

    /// Bind + listen; refuses to start when a live daemon already owns the socket.
    public func start() throws {
        if FileManager.default.fileExists(atPath: path) {
            if SocketClient.ping(socketPath: path) {
                throw ServerError.alreadyRunning(path)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.bindFailed(path) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ServerError.bindFailed(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count)))
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw ServerError.bindFailed(path)
        }
        chmod(path, 0o600)
        listenFD = fd

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "ybar-ipc"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let connection = accept(listenFD, nil, nil)
            guard connection >= 0 else { break }
            serve(connection: connection)
            close(connection)
        }
    }

    private func serve(connection: Int32) {
        // Both directions time out: the accept loop is serial, so a client that
        // connects and never reads its reply must not wedge all IPC forever.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafeBytes(of: &tv) { raw in
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, raw.baseAddress, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafeBytes(of: &tv) { raw in
            setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, raw.baseAddress, socklen_t(MemoryLayout<timeval>.size))
        }

        guard let header = SocketClient.readExactly(fd: connection, count: 4),
              let length = WireFormat.frameLength(header: header)
        else { return }
        let payload: Data
        if length > 0 {
            guard let body = SocketClient.readExactly(fd: connection, count: Int(length)) else { return }
            payload = body
        } else {
            payload = Data()
        }

        let arguments = WireFormat.decode(payload: payload)
        let handler = self.handler
        let reply = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                handler(arguments)
            }
        }
        _ = SocketClient.writeAll(fd: connection, data: WireFormat.frame(Data(reply.utf8)))
    }
}
