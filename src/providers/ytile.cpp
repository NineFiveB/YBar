#include "providers/ytile.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <algorithm>
#include <string>

#include <nlohmann/json.hpp>

namespace ybar::providers {

using nlohmann::json;

namespace {

constexpr const char* kPipePath = "\\\\.\\pipe\\ytile";
constexpr int kWorkspacesPerMonitor = 9; // fixed by the YTile protocol

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

// hwnd -> exe over every window (tiled + floating) of every workspace of
// every monitor — the app-lifecycle diff base. Hwnds may exceed 2^31
// (protocol note): parse as 64-bit.
std::vector<std::pair<long long, std::string>> collectWindows(const json& state) {
    std::vector<std::pair<long long, std::string>> windows;
    for (const auto& monitor : state.at("monitors")) {
        if (!monitor.contains("workspaces")) continue;
        for (const auto& workspace : monitor.at("workspaces")) {
            for (const auto* key : {"windows", "floating"}) {
                if (!workspace.contains(key)) continue;
                for (const auto& window : workspace.at(key)) {
                    if (!window.is_object() || !window.contains("hwnd")) continue;
                    windows.emplace_back(window.at("hwnd").get<long long>(),
                                         window.value("exe", std::string{}));
                }
            }
        }
    }
    std::sort(windows.begin(), windows.end());
    return windows;
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

namespace {

// Primary-monitor parse (YTile state has no global focused-monitor field —
// documented limitation, mirrored from the previous adapter). WORKSPACES
// shows non-empty OR active, ascending — the hiding behavior the protocol's
// own widget note recommends and the macOS AeroSpace adapter shipped.
std::optional<YTileUpdate> parseStateJson(const json& state) {
    try {
        const auto& monitors = state.at("monitors");
        if (monitors.empty()) return std::nullopt;
        const auto& monitor = monitors.at(0);
        const int active = monitor.value("active", 0);

        YTileUpdate update;
        update.focusedMonitorIndex = 0;
        update.focusedWorkspace = std::to_string(active + 1);
        if (monitor.contains("workspaces")) {
            const auto& workspaces = monitor.at("workspaces");
            for (int i = 0; i < static_cast<int>(workspaces.size()); ++i) {
                const auto& workspace = workspaces.at(i);
                const bool occupied =
                    (workspace.contains("windows") && !workspace.at("windows").empty()) ||
                    (workspace.contains("floating") && !workspace.at("floating").empty());
                if (!occupied && i != active) continue;
                if (!update.workspaceNames.empty()) update.workspaceNames += '\n';
                update.workspaceNames += std::to_string(i + 1);
                if (i == active)
                    update.focusedIndex =
                        1 + static_cast<int>(std::count(update.workspaceNames.begin(),
                                                        update.workspaceNames.end(), '\n'));
            }
        }
        if (update.workspaceNames.empty()) { // schema said no workspaces
            update.workspaceNames = update.focusedWorkspace;
            update.focusedIndex = 1;
        }
        update.workspacesChanged = true;
        return update;
    } catch (const json::exception&) {
        return std::nullopt;
    }
}

} // namespace

std::optional<YTileUpdate> YTileProvider::parseState(const std::string& stateJson) {
    try {
        return parseStateJson(json::parse(stateJson));
    } catch (const json::exception&) {
        return std::nullopt;
    }
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
            // The protocol's `ready` contract: reservations do not survive a
            // ytiled restart, and every (re)subscribe is the cue to
            // re-assert. Idempotent by design.
            const int offset = appliedOffset_.load();
            if (offset > 0) applyWorkAreaOffset(offset);

            // The stream only pushes on changes — pull the initial state so
            // the workspaces widget populates at boot (mirrors the
            // forced-query idiom, spec 11.3). Clear the dedupe first: after
            // a reconnect the state may be identical but subscribers just
            // lost their pipe-side continuity.
            {
                std::lock_guard<std::mutex> lock(stateMutex_);
                lastKey_.clear();
            }
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
    json state;
    try {
        state = json::parse(stateJson);
    } catch (const json::exception&) {
        return;
    }
    auto update = parseStateJson(state);
    if (!update) return;
    if (state.contains("monitors"))
        monitorCount_ = std::max(1, static_cast<int>(state.at("monitors").size()));

    // App lifecycle from window diffs (window-scoped, komorebi parity):
    // every notification is a full snapshot, so appeared/vanished hwnds are
    // exactly manage/unmanage.
    std::vector<std::pair<long long, std::string>> current;
    try {
        current = collectWindows(state);
    } catch (const json::exception&) {
    }
    std::vector<std::pair<std::string, std::string>> appEvents;
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        if (onAppEvent && windowsPrimed_) {
            for (const auto& [hwnd, exe] : current) {
                const bool existed = std::binary_search(
                    knownWindows_.begin(), knownWindows_.end(), std::make_pair(hwnd, exe));
                if (!existed && !exe.empty()) appEvents.emplace_back("app_launched", exe);
            }
            for (const auto& [hwnd, exe] : knownWindows_) {
                const bool remains = std::binary_search(current.begin(), current.end(),
                                                        std::make_pair(hwnd, exe));
                if (!remains && !exe.empty()) appEvents.emplace_back("app_terminated", exe);
            }
        }
        knownWindows_ = std::move(current);
        windowsPrimed_ = true; // never announce the pre-existing world

        // Dedupe on focused + shown list: occupancy changes must repaint the
        // pill strip even when focus did not move.
        const std::string key = update->focusedWorkspace + "\x1f" + update->workspaceNames;
        update->previousWorkspace = lastFocusedName_;
        const bool duplicate = (key == lastKey_);
        lastKey_ = key;
        lastFocusedName_ = update->focusedWorkspace;
        lastActive_ = std::max(0, std::stoi(update->focusedWorkspace) - 1);
        shownNumbers_.clear();
        for (size_t start = 0, end = 0; end != std::string::npos; start = end + 1) {
            end = update->workspaceNames.find('\n', start);
            const std::string token = update->workspaceNames.substr(
                start, end == std::string::npos ? std::string::npos : end - start);
            if (!token.empty()) shownNumbers_.push_back(std::stoi(token));
        }
        if (duplicate) {
            update.reset();
        }
    }
    for (const auto& [event, exe] : appEvents)
        if (onAppEvent) onAppEvent(event, exe);
    if (update && onUpdate) onUpdate(*update);
}

bool YTileProvider::refresh() {
    std::string reply;
    if (!sendCommand("state", "", &reply)) return false;
    try {
        const auto parsed = json::parse(reply);
        if (!parsed.contains("state")) return false;
        {
            std::lock_guard<std::mutex> lock(stateMutex_);
            lastKey_.clear(); // forced re-query always republishes
        }
        handleState(parsed.at("state").dump());
        return true;
    } catch (const json::exception&) {
        return false;
    }
}

bool YTileProvider::focusListIndex(int zeroBasedListIndex) {
    int number = 0;
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        if (zeroBasedListIndex < 0 ||
            zeroBasedListIndex >= static_cast<int>(shownNumbers_.size()))
            return false;
        number = shownNumbers_[static_cast<std::size_t>(zeroBasedListIndex)];
    }
    return sendCommand("workspace", std::to_string(number));
}

bool YTileProvider::focusNamed(const std::string& name) {
    // YTile workspaces have no names; the published "names" ARE the numbers.
    if (name.empty() || name.find_first_not_of("0123456789") != std::string::npos)
        return false;
    return sendCommand("workspace", name);
}

bool YTileProvider::cycleWorkspace(bool next) {
    int target = 0;
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        const int delta = next ? 1 : -1;
        target = ((lastActive_ + delta) % kWorkspacesPerMonitor + kWorkspacesPerMonitor) %
                     kWorkspacesPerMonitor +
                 1;
    }
    return sendCommand("workspace", std::to_string(target));
}

void YTileProvider::applyWorkAreaOffset(int barHeightPhysical) {
    appliedOffset_ = barHeightPhysical; // replayed after every reconnect
    for (int i = 0; i < monitorCount_; ++i) {
        sendCommand("reserve",
                    std::to_string(i) + " 0 " + std::to_string(barHeightPhysical) + " 0 0");
    }
}

void YTileProvider::clearWorkAreaOffset() {
    appliedOffset_ = 0;
    for (int i = 0; i < monitorCount_; ++i) {
        sendCommand("reserve", std::to_string(i) + " 0 0 0 0");
    }
}

} // namespace ybar::providers
