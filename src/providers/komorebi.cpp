#include "providers/komorebi.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <afunix.h>
#include <windows.h>
// clang-format on

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <nlohmann/json.hpp>

#include "ipc/socket.h"

namespace ybar::providers {

using nlohmann::json;

namespace {

std::string komorebiDir() {
    const char* localAppData = std::getenv("LOCALAPPDATA");
    return std::string(localAppData ? localAppData : "") + "\\komorebi";
}

std::string komorebiSocket() { return komorebiDir() + "\\komorebi.sock"; }

// Tolerant extraction of the focused workspace from a full State snapshot
// (spec 11.2: unknown fields ignored; name nullable -> 1-based index).
KomorebiUpdate extractUpdate(const json& state) {
    KomorebiUpdate update;
    const auto& monitors = state.at("monitors");
    const auto focusedMonitor = monitors.value("focused", 0);
    update.focusedMonitorIndex = static_cast<int>(focusedMonitor);
    const auto& elements = monitors.at("elements");
    if (focusedMonitor >= elements.size()) return update;
    const auto& workspaces = elements.at(focusedMonitor).at("workspaces");
    const auto focusedWs = workspaces.value("focused", 0);
    const auto& wsElements = workspaces.at("elements");
    if (focusedWs >= wsElements.size()) return update;
    const auto& workspace = wsElements.at(focusedWs);
    if (workspace.contains("name") && workspace.at("name").is_string()) {
        update.focusedWorkspace = workspace.at("name").get<std::string>();
    } else {
        update.focusedWorkspace = std::to_string(focusedWs + 1);
    }
    update.workspacesChanged = true;
    return update;
}

} // namespace

bool KomorebiProvider::detect() {
    return GetFileAttributesA(komorebiSocket().c_str()) != INVALID_FILE_ATTRIBUTES;
}

KomorebiProvider::KomorebiProvider() = default;
KomorebiProvider::~KomorebiProvider() { stop(); }

bool KomorebiProvider::sendMessage(const std::string& jsonText) {
    return ybar::ipc::rawSend(komorebiSocket(), jsonText);
}

bool KomorebiProvider::start(const std::string& subscriberName) {
    if (!ybar::ipc::ensureWinsockInitialized()) return false;
    subscriberName_ = subscriberName;
    subscriberPath_ = komorebiDir() + "\\" + subscriberName; // name verbatim, no .sock appended

    DeleteFileA(subscriberPath_.c_str());
    const SOCKET sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) return false;
    SOCKADDR_UN address{};
    address.sun_family = AF_UNIX;
    if (subscriberPath_.size() >= sizeof(address.sun_path)) {
        closesocket(sock);
        return false;
    }
    std::memcpy(address.sun_path, subscriberPath_.c_str(), subscriberPath_.size() + 1);
    if (bind(sock, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0 ||
        listen(sock, 4) != 0) {
        closesocket(sock);
        return false;
    }
    listenSocket_ = static_cast<std::uintptr_t>(sock);

    const std::string registration =
        json{{"type", "AddSubscriberSocketWithOptions"},
             {"content", json::array({subscriberName_, {{"filter_state_changes", true}}})}}
            .dump();
    if (!sendMessage(registration)) {
        closesocket(sock);
        DeleteFileA(subscriberPath_.c_str());
        return false;
    }

    running_ = true;
    thread_ = std::thread([this] { readerLoop(); });
    return true;
}

void KomorebiProvider::stop() {
    if (!running_.exchange(false)) return;
    closesocket(static_cast<SOCKET>(listenSocket_));
    if (thread_.joinable()) thread_.join();
    ybar::ipc::rawSend(komorebiSocket(),
                       json{{"type", "RemoveSubscriberSocket"}, {"content", subscriberName_}}
                           .dump());
    DeleteFileA(subscriberPath_.c_str());
}

void KomorebiProvider::reregister() {
    // komorebi died or pruned us: retry every 1 s until it takes, then
    // re-apply the offset and re-publish state (spec 11.3).
    while (running_) {
        const std::string registration =
            json{{"type", "AddSubscriberSocketWithOptions"},
                 {"content", json::array({subscriberName_, {{"filter_state_changes", true}}})}}
                .dump();
        if (sendMessage(registration)) {
            if (appliedOffset_ > 0) applyWorkAreaOffset(appliedOffset_);
            lastFocused_.clear(); // force the next state through the dedupe
            if (const auto reply = ybar::ipc::rawQuery(komorebiSocket(), json{{"type", "State"}}.dump()))
                publishState(*reply);
            return;
        }
        Sleep(1000);
    }
}

void KomorebiProvider::readerLoop() {
    // One notification per connection: accept -> read to EOF -> parse
    // (verified v0.1.41 framing, spec 11.1).
    while (running_) {
        const SOCKET connection = accept(static_cast<SOCKET>(listenSocket_), nullptr, nullptr);
        if (connection == INVALID_SOCKET) {
            if (!running_) break;
            reregister();
            continue;
        }
        std::string payload;
        char buffer[16384];
        for (;;) {
            const int n = recv(connection, buffer, sizeof(buffer), 0);
            if (n <= 0) break;
            payload.append(buffer, static_cast<std::size_t>(n));
        }
        closesocket(connection);
        if (payload.empty()) {
            // Zero-byte read: komorebi shut the connection without a
            // notification — the documented "it died" signal (spec 11.3).
            if (!ybar::ipc::rawSend(komorebiSocket(), json{{"type", "State"}}.dump()))
                reregister();
            continue;
        }

        publishState(payload);
    }
}

// Window lifecycle from the notification's `event` field: komorebi's
// Show/Destroy carry the window, so app_launched/app_terminated are
// window-scoped here (spec 10) rather than process-scoped.
namespace {
void publishAppEvent(
    const json& parsed,
    const std::function<void(const std::string&, const std::string&)>& onAppEvent) {
    if (!onAppEvent || !parsed.contains("event")) return;
    const auto& event = parsed.at("event");
    if (!event.is_object() || !event.contains("type")) return;
    const auto type = event.at("type").get<std::string>();
    const char* name = type == "Show" ? "app_launched"
                       : type == "Destroy" ? "app_terminated"
                                           : nullptr;
    if (!name || !event.contains("content")) return;
    // content is a tuple whose window element is the object carrying `exe`.
    const auto& content = event.at("content");
    if (!content.is_array()) return;
    for (const auto& element : content) {
        if (!element.is_object() || !element.contains("exe")) continue;
        const auto exe = element.at("exe").get<std::string>();
        if (!exe.empty()) onAppEvent(name, exe);
        return;
    }
}
} // namespace

// Accepts either a full {event, state} notification or a bare State reply.
void KomorebiProvider::publishState(const std::string& payload) {
    try {
        const auto parsed = json::parse(payload);
        publishAppEvent(parsed, onAppEvent);
        const auto& state = parsed.contains("state") ? parsed.at("state") : parsed;
        if (!state.contains("monitors")) return;
        monitorCount_ = static_cast<int>(state.at("monitors").at("elements").size());
        monitorCountKnown_ = true;
        auto update = extractUpdate(state);
        if (!update.workspacesChanged) return;
        update.previousWorkspace = lastFocused_;
        // Dedupe on monitor+workspace: two monitors can focus workspaces with
        // the same display string (spec 11.3 fires on monitor OR workspace).
        const std::string key =
            std::to_string(update.focusedMonitorIndex) + "\x1f" + update.focusedWorkspace;
        if (key == lastFocused_) return;
        lastFocused_ = key;
        if (onUpdate) onUpdate(update);
    } catch (const json::exception&) {
        // Tolerant parsing: schema drift must not kill the provider.
    }
}

bool KomorebiProvider::refresh() {
    const auto reply = ybar::ipc::rawQuery(komorebiSocket(), json{{"type", "State"}}.dump());
    if (!reply) return false;
    lastFocused_.clear(); // forced re-query always republishes
    publishState(*reply);
    return true;
}

void KomorebiProvider::applyWorkAreaOffset(int barHeightPhysical) {
    appliedOffset_ = barHeightPhysical; // replayed after a reconnect
    // Learn the real monitor count before the first notification arrives,
    // otherwise a multi-monitor setup only ever reserves monitor 0.
    if (!monitorCountKnown_) {
        if (const auto reply =
                ybar::ipc::rawQuery(komorebiSocket(), json{{"type", "State"}}.dump())) {
            try {
                const auto state = json::parse(*reply);
                monitorCount_ =
                    static_cast<int>(state.at("monitors").at("elements").size());
                monitorCountKnown_ = true;
            } catch (const json::exception&) {
            }
        }
    }
    // {left:0, top:H, right:0, bottom:H} — bottom is a HEIGHT reduction;
    // top alone would push tiles off-screen (spec 11.4).
    for (int i = 0; i < monitorCount_; ++i) {
        const std::string message =
            json{{"type", "MonitorWorkAreaOffset"},
                 {"content", json::array({i, {{"left", 0},
                                              {"top", barHeightPhysical},
                                              {"right", 0},
                                              {"bottom", barHeightPhysical}}})}}
                .dump();
        sendMessage(message);
    }
}

void KomorebiProvider::clearWorkAreaOffset() {
    for (int i = 0; i < monitorCount_; ++i) {
        const std::string message =
            json{{"type", "MonitorWorkAreaOffset"},
                 {"content",
                  json::array({i, {{"left", 0}, {"top", 0}, {"right", 0}, {"bottom", 0}}})}}
                .dump();
        sendMessage(message);
    }
}

} // namespace ybar::providers
