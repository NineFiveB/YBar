import Foundation
import Testing
@testable import YBarKit

/// End-to-end AF_UNIX transport: a real SocketServer answering a real
/// SocketClient inside this process (the port pins the same round trip in
/// socket_tests.cpp). The server's handler hops through the main queue, so
/// this suite deliberately runs OFF the main actor: the client blocks on a
/// cooperative thread while the runner's main thread serves the hop. A
/// main-actor test blocked inside SocketClient.send could never answer
/// itself, and a nested run loop cannot drain the main queue from inside a
/// main-queue job either. Every wait below is bounded by a socket timeout,
/// so a regression fails instead of stalling CI.
@Suite(.serialized) struct SocketRoundTripTests {
    private final class Slot<T>: @unchecked Sendable {
        var value: T?
    }

    /// sun_path is 104 bytes, so the nodes live in /tmp like the daemon's.
    private static func scratchPath() -> String {
        "/tmp/ybar-test-\(UUID().uuidString.prefix(8)).socket"
    }

    @Test func serverAndClientRoundTripFramedArgv() throws {
        let path = Self.scratchPath()
        let received = Slot<[String]>()
        let server = SocketServer(path: path) { arguments in
            received.value = arguments
            return "pong"
        }
        try server.start()
        defer { server.stop() }

        let reply = try SocketClient.send(arguments: ["--ping", "with space", "eq=a=b"], socketPath: path)
        #expect(reply == "pong")
        #expect(received.value == ["--ping", "with space", "eq=a=b"])
    }

    @Test func emptyRepliesArriveAsEmptyStrings() throws {
        let path = Self.scratchPath()
        let server = SocketServer(path: path) { _ in "" }
        try server.start()
        defer { server.stop() }

        #expect(try SocketClient.send(arguments: ["--update"], socketPath: path) == "")
    }

    @Test func secondServerOnALivePathRefusesUntilTheFirstStops() throws {
        let path = Self.scratchPath()
        let first = SocketServer(path: path) { _ in "pong" }
        try first.start()

        // start() pings the live node, which answers through the main queue.
        let second = SocketServer(path: path) { _ in "pong" }
        var error: SocketServer.ServerError?
        do { try second.start() } catch let caught as SocketServer.ServerError { error = caught }
        guard case .alreadyRunning = error else {
            Issue.record("expected alreadyRunning, got \(String(describing: error))")
            first.stop()
            return
        }

        first.stop()
        // The node went with the first server; the path is free to bind again.
        let third = SocketServer(path: path) { _ in "pong" }
        try third.start()
        #expect(SocketClient.ping(socketPath: path))
        third.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func deadNodeIsRecycled() throws {
        // A leftover from a crashed daemon: nobody answers, so it is unlinked
        // and rebound rather than reported as a live instance.
        let path = Self.scratchPath()
        FileManager.default.createFile(atPath: path, contents: nil)
        let server = SocketServer(path: path) { _ in "pong" }
        try server.start()
        defer { server.stop() }
        #expect(SocketClient.ping(socketPath: path))
    }

    @Test func clientReportsTransportFailureForADeadPath() {
        let path = Self.scratchPath()
        #expect(throws: SocketClient.ClientError.self) {
            try SocketClient.send(arguments: ["--ping"], socketPath: path, timeout: 0.5)
        }
        #expect(!SocketClient.ping(socketPath: path))
    }
}
