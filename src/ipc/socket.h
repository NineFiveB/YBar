// AF_UNIX transport over Winsock (spec sections 3.1, 5.1). The socket file is
// the single-instance lock: an existing file that answers --ping means a live
// daemon; a dead file is deleted and rebound.

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ybar::ipc {

// Process-wide WSAStartup (idempotent). Any code creating sockets outside
// this module must call it first.
bool ensureWinsockInitialized();

// Blocking client round-trip: connect, send one framed argv message, read one
// framed reply. nullopt on any transport failure.
std::optional<std::string> clientSend(const std::string& path,
                                      const std::vector<std::string>& argv,
                                      double timeoutSeconds = 5.0);

// Unframed raw send for foreign protocols (komorebi: one JSON per
// connection, no delimiter). false on transport failure.
bool rawSend(const std::string& path, const std::string& bytes, double timeoutSeconds = 1.0);

// Unframed raw query: write, shutdown the send side, read the reply to EOF
// (komorebi State/GlobalState queries).
std::optional<std::string> rawQuery(const std::string& path, const std::string& bytes,
                                    double timeoutSeconds = 2.0);

class SocketServer {
public:
    ~SocketServer();

    // Handler runs on the accept thread — the daemon marshals to its UI
    // thread inside this callback and returns the reply.
    using Handler = std::function<std::string(const std::vector<std::string>&)>;

    // Binds the socket and claims the instance lock — call FIRST at boot, so a
    // second launch fails before touching shared state (spec 5). Returns an
    // error string on failure ("[!] another ybar daemon is already running
    // (socket: <path>)", "[!] could not bind socket at <path>").
    std::optional<std::string> reserve(const std::string& path);

    // Starts the accept loop on an already-reserved socket.
    void serve(Handler handler);

    // reserve() + serve() in one call (tests).
    std::optional<std::string> start(const std::string& path, Handler handler);
    void stop();

private:
    void acceptLoop();

    std::string path_;
    Handler handler_;
    std::uintptr_t listenSocket_ = ~0ull; // INVALID_SOCKET without winsock2.h here
    std::thread thread_;
    std::atomic<bool> running_{false};
};

} // namespace ybar::ipc
