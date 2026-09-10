import AppKit
import Foundation
import Testing
@testable import YBarKit

/// Stand-in for a daemon living in another process: owns a listening node and
/// answers every request from its own thread. It deliberately bypasses
/// SocketServer, whose handler hops through the main queue — a main-actor
/// test blocked inside `SocketClient.ping` could never answer itself.
final class LiveNode: @unchecked Sendable {
    let path: String
    private let fd: Int32

    init(path: String) throws {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count)))
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            throw SocketServer.ServerError.bindFailed(path)
        }
        let listenFD = fd
        let thread = Thread {
            while true {
                let connection = accept(listenFD, nil, nil)
                guard connection >= 0 else { return }
                if let header = SocketClient.readExactly(fd: connection, count: 4),
                   let length = WireFormat.frameLength(header: header) {
                    if length > 0 { _ = SocketClient.readExactly(fd: connection, count: Int(length)) }
                    _ = SocketClient.writeAll(fd: connection, data: WireFormat.frame(Data("pong".utf8)))
                }
                close(connection)
            }
        }
        thread.name = "ybar-test-live-node"
        thread.start()
    }

    func shutdown() {
        close(fd)
        unlink(path)
    }
}

/// sun_path is 104 bytes, so the nodes live in /tmp exactly like the daemon's.
private func scratchSocketPath() -> String {
    "/tmp/ybar-test-\(UUID().uuidString.prefix(8)).socket"
}

@Suite(.serialized) struct SocketServerTests {
    @Test func losingTheInstanceRaceLeavesTheLiveNodeAlone() throws {
        let path = scratchSocketPath()
        let live = try LiveNode(path: path)
        defer { live.shutdown() }

        let loser = SocketServer(path: path) { _ in "" }
        var error: SocketServer.ServerError?
        do { try loser.start() } catch let caught as SocketServer.ServerError { error = caught }
        guard case .alreadyRunning = error else {
            Issue.record("expected alreadyRunning, got \(String(describing: error))")
            return
        }
        // applicationWillTerminate stops the server on the way out; the node
        // it never bound must still be there and still answering.
        loser.stop()
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(SocketClient.ping(socketPath: path))
    }

    @Test func stopWithoutBindNeverUnlinks() {
        let path = scratchSocketPath()
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { unlink(path) }
        SocketServer(path: path) { _ in "" }.stop()
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func nodeIsOwnerOnlyAndUmaskIsRestored() throws {
        let path = scratchSocketPath()
        let before = umask(0o022)
        defer { umask(before) }
        let server = SocketServer(path: path) { _ in "" }
        try server.start()
        defer { server.stop() }
        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(umask(0o022) == 0o022)
    }

    @Test func boundNodeIsRemovedOnStop() throws {
        let path = scratchSocketPath()
        let server = SocketServer(path: path) { _ in "" }
        try server.start()
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// The instance lock comes before windows and providers: a second launch
    /// against a live daemon bails out with no surface created and the live
    /// daemon's socket untouched.
    @MainActor
    @Test func secondLaunchFailsBeforeWindowsOrProvidersExist() throws {
        let path = scratchSocketPath()
        let live = try LiveNode(path: path)
        defer { live.shutdown() }

        let core = try DaemonCore(explicitConfigPath: nil)
        core.socketPath = path
        var threw = false
        do { try core.bindInstanceSocket() } catch { threw = true }
        #expect(threw)
        core.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(core.barManager.surfaces.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(SocketClient.ping(socketPath: path))
    }
}
