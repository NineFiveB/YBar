#include "ipc/socket.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <afunix.h>
#include <windows.h>
// clang-format on

#include <aclapi.h>

#include <cstring>
#include <vector>

#include "ipc/wire_format.h"

namespace ybar::ipc {

namespace {

// Process-wide Winsock init (client role and daemon both pass through here).
bool ensureWinsock() {
    static const bool ready = [] {
        WSADATA data;
        return WSAStartup(MAKEWORD(2, 2), &data) == 0;
    }();
    return ready;
}

void setTimeouts(SOCKET socket, double seconds) {
    const DWORD ms = static_cast<DWORD>(seconds * 1000.0);
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&ms), sizeof(ms));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&ms), sizeof(ms));
}

bool sendAll(SOCKET socket, const std::uint8_t* data, std::size_t size) {
    std::size_t sent = 0;
    while (sent < size) {
        const int n = send(socket, reinterpret_cast<const char*>(data + sent),
                           static_cast<int>(size - sent), 0);
        if (n <= 0) return false;
        sent += static_cast<std::size_t>(n);
    }
    return true;
}

bool recvExactly(SOCKET socket, std::uint8_t* data, std::size_t size) {
    std::size_t received = 0;
    while (received < size) {
        const int n = recv(socket, reinterpret_cast<char*>(data + received),
                           static_cast<int>(size - received), 0);
        if (n <= 0) return false;
        received += static_cast<std::size_t>(n);
    }
    return true;
}

std::optional<std::vector<std::uint8_t>> recvFrame(SOCKET socket) {
    std::uint8_t header[4];
    if (!recvExactly(socket, header, 4)) return std::nullopt;
    const auto length = frameLength(header);
    if (!length) return std::nullopt; // oversize frame: protocol error, drop
    std::vector<std::uint8_t> payload(*length);
    if (*length > 0 && !recvExactly(socket, payload.data(), payload.size())) return std::nullopt;
    return payload;
}

// Restrict the socket file to the current user (spec 5.1: the macOS
// chmod 0600 equivalent — this endpoint executes commands unauthenticated).
void restrictToCurrentUser(const std::string& path) {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return;
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (size == 0 || !GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
        CloseHandle(token);
        return;
    }
    auto* user = reinterpret_cast<TOKEN_USER*>(buffer.data());

    EXPLICIT_ACCESSW access{};
    access.grfAccessPermissions = GENERIC_ALL;
    access.grfAccessMode = SET_ACCESS;
    access.grfInheritance = NO_INHERITANCE;
    access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    access.Trustee.TrusteeType = TRUSTEE_IS_USER;
    access.Trustee.ptstrName = static_cast<LPWSTR>(user->User.Sid);

    PACL acl = nullptr;
    if (SetEntriesInAclW(1, &access, nullptr, &acl) == ERROR_SUCCESS && acl) {
        const std::wstring widePath(path.begin(), path.end());
        SetNamedSecurityInfoW(const_cast<LPWSTR>(widePath.c_str()), SE_FILE_OBJECT,
                              DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                              nullptr, nullptr, acl, nullptr);
        LocalFree(acl);
    }
    CloseHandle(token);
}

bool connectTo(SOCKET socket, const std::string& path) {
    SOCKADDR_UN address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) return false;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    return connect(socket, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0;
}

} // namespace

bool ensureWinsockInitialized() { return ensureWinsock(); }

std::optional<std::string> clientSend(const std::string& path,
                                      const std::vector<std::string>& argv,
                                      double timeoutSeconds) {
    if (!ensureWinsock()) return std::nullopt;
    const SOCKET sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) return std::nullopt;
    setTimeouts(sock, timeoutSeconds);

    std::optional<std::string> reply;
    if (connectTo(sock, path)) {
        const auto framed = frame(encode(argv));
        if (sendAll(sock, framed.data(), framed.size())) {
            if (const auto payload = recvFrame(sock)) {
                reply = std::string(payload->begin(), payload->end());
            }
        }
    }
    closesocket(sock);
    return reply;
}

bool rawSend(const std::string& path, const std::string& bytes, double timeoutSeconds) {
    if (!ensureWinsock()) return false;
    const SOCKET sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) return false;
    setTimeouts(sock, timeoutSeconds);
    bool ok = false;
    if (connectTo(sock, path)) {
        ok = sendAll(sock, reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size());
    }
    closesocket(sock);
    return ok;
}

std::optional<std::string> rawQuery(const std::string& path, const std::string& bytes,
                                    double timeoutSeconds) {
    if (!ensureWinsock()) return std::nullopt;
    const SOCKET sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) return std::nullopt;
    setTimeouts(sock, timeoutSeconds);
    std::optional<std::string> reply;
    if (connectTo(sock, path) &&
        sendAll(sock, reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size())) {
        shutdown(sock, SD_SEND);
        std::string received;
        char buffer[8192];
        for (;;) {
            const int n = recv(sock, buffer, sizeof(buffer), 0);
            if (n <= 0) break;
            received.append(buffer, static_cast<std::size_t>(n));
        }
        if (!received.empty()) reply = std::move(received);
    }
    closesocket(sock);
    return reply;
}

SocketServer::~SocketServer() { stop(); }

std::optional<std::string> SocketServer::start(const std::string& path, Handler handler) {
    if (const auto error = reserve(path)) return error;
    serve(std::move(handler));
    return std::nullopt;
}

void SocketServer::serve(Handler handler) {
    if (listenSocket_ == static_cast<std::uintptr_t>(~0ull) || running_) return;
    handler_ = std::move(handler);
    running_ = true;
    thread_ = std::thread([this] {
        SetThreadDescription(GetCurrentThread(), L"ybar-ipc"); // spec 3.1
        acceptLoop();
    });
}

std::optional<std::string> SocketServer::reserve(const std::string& path) {
    if (!ensureWinsock()) return "[!] could not bind socket at " + path;

    // Instance lock: a live daemon answers --ping; a stale file is deleted.
    if (GetFileAttributesA(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
        if (const auto reply = clientSend(path, {"--ping"}, 1.0); reply && *reply == "pong")
            return "[!] another ybar daemon is already running (socket: " + path + ")";
        DeleteFileA(path.c_str());
    }

    // Parent directory (e.g. %LOCALAPPDATA%\ybar) may not exist yet.
    const auto slash = path.find_last_of("\\/");
    if (slash != std::string::npos) CreateDirectoryA(path.substr(0, slash).c_str(), nullptr);

    const SOCKET sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) return "[!] could not bind socket at " + path;

    SOCKADDR_UN address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) {
        closesocket(sock);
        return "[!] could not bind socket at " + path;
    }
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    if (bind(sock, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0 ||
        listen(sock, 16) != 0) {
        closesocket(sock);
        return "[!] could not bind socket at " + path;
    }

    restrictToCurrentUser(path);

    path_ = path;
    listenSocket_ = static_cast<std::uintptr_t>(sock);
    return std::nullopt;
}

void SocketServer::stop() {
    const bool wasRunning = running_.exchange(false);
    if (listenSocket_ == static_cast<std::uintptr_t>(~0ull)) return;
    closesocket(static_cast<SOCKET>(listenSocket_)); // unblocks accept()
    listenSocket_ = static_cast<std::uintptr_t>(~0ull);
    if (wasRunning && thread_.joinable()) thread_.join();
    DeleteFileA(path_.c_str());
}

void SocketServer::acceptLoop() {
    // Serial accept loop — one connection at a time, 2 s per-connection
    // timeouts as wedge protection (reference behavior).
    while (running_) {
        const SOCKET connection = accept(static_cast<SOCKET>(listenSocket_), nullptr, nullptr);
        if (connection == INVALID_SOCKET) {
            if (!running_) break;
            continue;
        }
        setTimeouts(connection, 2.0);
        if (const auto payload = recvFrame(connection)) {
            const auto argv = decode(payload->data(), payload->size());
            const std::string reply = handler_ ? handler_(argv) : std::string();
            std::vector<std::uint8_t> bytes(reply.begin(), reply.end());
            const auto framed = frame(bytes);
            sendAll(connection, framed.data(), framed.size());
        }
        closesocket(connection);
    }
}

} // namespace ybar::ipc
