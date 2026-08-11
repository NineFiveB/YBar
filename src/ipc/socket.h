// AF_UNIX transport over Winsock (spec sections 3.1, 5.1). The socket file is
// the single-instance lock: an existing file that answers --ping means a live
// daemon; a dead file is deleted and rebound.

#pragma once

#include <atomic>
#include <functional>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ybar::ipc {

// Blocking client round-trip: connect, send one framed argv message, read one
// framed reply. nullopt on any transport failure.
std::optional<std::string> clientSend(const std::string& path,
                                      const std::vector<std::string>& argv,
                                      double timeoutSeconds = 5.0);

class SocketServer {
public:
    ~SocketServer();

    // Handler runs on the accept thread — the daemon marshals to its UI
    // thread inside this callback and returns the reply.
    using Handler = std::function<std::string(const std::vector<std::string>&)>;

    // Returns an error string on failure ("[!] another ybar daemon is already
    // running (socket: <path>)", "[!] could not bind socket at <path>").
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
