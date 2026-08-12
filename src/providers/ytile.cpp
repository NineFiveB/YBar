#include "providers/ytile.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <string>

#include <nlohmann/json.hpp>

namespace ybar::providers {

using nlohmann::json;

namespace {

constexpr const char* kPipePath = "\\\\.\\pipe\\ytile";

// Opens a client connection; retries briefly when all instances are busy.
HANDLE openPipe() {
    for (int attempt = 0; attempt < 3; ++attempt) {
        const HANDLE pipe = CreateFileA(kPipePath, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                        OPEN_EXISTING, 0, nullptr);
        if (pipe != INVALID_HANDLE_VALUE) return pipe;
        if (GetLastError() != ERROR_PIPE_BUSY) break;
        if (!WaitNamedPipeA(kPipePath, 500)) break;
    }
    return INVALID_HANDLE_VALUE;
}

bool writeLine(HANDLE pipe, const std::string& line) {
    const std::string framed = line + "\n";
    DWORD written = 0;
    return WriteFile(pipe, framed.data(), static_cast<DWORD>(framed.size()), &written, nullptr) &&
           written == framed.size();
}

// Reads until '\n' (exclusive). Returns false on disconnect/error.
bool readLine(HANDLE pipe, std::string& buffer, std::string& line) {
    for (;;) {
        const auto newline = buffer.find('\n');
        if (newline != std::string::npos) {
            line = buffer.substr(0, newline);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            buffer.erase(0, newline + 1);
            return true;
        }
        char chunk[16384];
        DWORD n = 0;
        if (!ReadFile(pipe, chunk, sizeof(chunk), &n, nullptr) || n == 0) return false;
        buffer.append(chunk, n);
    }
}

} // namespace

bool YTileProvider::detect() {
    return WaitNamedPipeA(kPipePath, 0) || GetLastError() == ERROR_SEM_TIMEOUT;
}

YTileProvider::YTileProvider() = default;
YTileProvider::~YTileProvider() { stop(); }

bool YTileProvider::sendCommand(const std::string& cmd, const std::string& arg,
                                std::string* replyLine) {
    const HANDLE pipe = openPipe();
    if (pipe == INVALID_HANDLE_VALUE) return false;
    json request{{"cmd", cmd}};
    if (!arg.empty()) request["arg"] = arg;
    bool ok = writeLine(pipe, request.dump());
    if (ok) {
        std::string buffer;
        std::string line;
        ok = readLine(pipe, buffer, line);
        if (ok && replyLine) *replyLine = line;
    }
    CloseHandle(pipe);
    return ok;
}

bool YTileProvider::start() {
    if (running_.exchange(true)) return true;
    thread_ = std::thread([this] { readerLoop(); });
    return true;
}

void YTileProvider::stop() {
    if (!running_.exchange(false)) return;
    const auto pipe = pipe_.exchange(-1);
    if (pipe != -1) CloseHandle(reinterpret_cast<HANDLE>(pipe));
    if (thread_.joinable()) thread_.join();
}

void YTileProvider::readerLoop() {
    while (running_) {
        const HANDLE pipe = openPipe();
        if (pipe == INVALID_HANDLE_VALUE) {
            Sleep(1000);
            continue;
        }
        pipe_.store(reinterpret_cast<std::intptr_t>(pipe));

        std::string buffer;
        std::string line;
        bool subscribed = writeLine(pipe, R"({"cmd":"subscribe"})") &&
                          readLine(pipe, buffer, line); // ack: {"ok":true,...}

        if (subscribed) {
            // The stream only pushes on changes — pull the initial state so
            // the workspaces widget populates at boot (mirrors the
            // forced-query idiom, spec 11.3).
            std::string stateReply;
            if (sendCommand("state", "", &stateReply)) {
                try {
                    const auto reply = json::parse(stateReply);
                    if (reply.contains("state")) handleState(reply.at("state").dump());
                } catch (const json::exception&) {
                }
            }

            while (running_ && readLine(pipe, buffer, line)) {
                try {
                    const auto notification = json::parse(line);
                    if (notification.contains("state")) {
                        handleState(notification.at("state").dump());
                    }
                } catch (const json::exception&) {
                    // Tolerant parsing: schema drift must not kill the provider.
                }
            }
        }

        const auto stored = pipe_.exchange(-1);
        if (stored != -1) CloseHandle(reinterpret_cast<HANDLE>(stored));
        if (running_) Sleep(1000); // ytiled restarting — reconnect loop
    }
}

void YTileProvider::handleState(const std::string& stateJson) {
    try {
        const auto state = json::parse(stateJson);
        const auto& monitors = state.at("monitors");
        if (monitors.empty()) return;
        monitorCount_ = static_cast<int>(monitors.size());

        // YTile state carries no focused-monitor field yet; report the
        // primary (index 0) monitor's active workspace.
        const auto& monitor = monitors.at(0);
        const int active = monitor.value("active", 0);

        YTileUpdate update;
        update.focusedMonitorIndex = 0;
        update.focusedWorkspace = std::to_string(active + 1);
        update.workspacesChanged = true;
        if (update.focusedWorkspace == lastFocused_) return; // dedupe
        update.previousWorkspace = lastFocused_;
        lastFocused_ = update.focusedWorkspace;
        if (onUpdate) onUpdate(update);
    } catch (const json::exception&) {
    }
}

bool YTileProvider::refresh() {
    std::string reply;
    if (!sendCommand("state", "", &reply)) return false;
    try {
        const auto parsed = json::parse(reply);
        if (!parsed.contains("state")) return false;
        lastFocused_.clear(); // forced re-query always republishes
        handleState(parsed.at("state").dump());
        return true;
    } catch (const json::exception&) {
        return false;
    }
}

void YTileProvider::applyWorkAreaOffset(int barHeightPhysical) {
    for (int i = 0; i < monitorCount_; ++i) {
        sendCommand("reserve",
                    std::to_string(i) + " 0 " + std::to_string(barHeightPhysical) + " 0 0");
    }
}

void YTileProvider::clearWorkAreaOffset() {
    for (int i = 0; i < monitorCount_; ++i) {
        sendCommand("reserve", std::to_string(i) + " 0 0 0 0");
    }
}

} // namespace ybar::providers
