#include "app/client.h"

#include <cstdio>
#include <cstdlib>

#include "app/local_verbs.h"
#include "ipc/wire_format.h"
#include "ipc/socket.h"

namespace ybar::app {

namespace {

constexpr char kVersion[] = "0.1.0";

constexpr char kHelp[] =
    "ybar — a GPU-rendered, scriptable status bar for Windows.\n"
    "\n"
    "  ybar                       start the daemon\n"
    "  ybar -c <path>             start the daemon with an explicit config\n"
    "  ybar --bar height=32 color=0xcc1e1e2e\n"
    "  ybar --add item clock right\n"
    "  ybar --set clock label=\"12:00\" icon=sf:clock\n"
    "  ybar --subscribe clock system_woke\n"
    "  ybar --animate tanh 30 --set clock label.color=0xffff0000\n"
    "  ybar --query bar\n"
    "\n"
    "  ybar theme list|current|use <name>\n"
    "  ybar autostart enable|disable|status\n"
    "\n"
    "Design: docs/WINDOWS-PORT.md\n";

bool hasToken(const std::vector<std::string>& argv, const std::string& prefix) {
    for (const auto& token : argv)
        if (token.rfind(prefix, 0) == 0) return true;
    return false;
}

std::vector<std::pair<std::string, std::string>> processEnvironment() {
    std::vector<std::pair<std::string, std::string>> result;
    for (char** entry = _environ; entry && *entry; ++entry) {
        const std::string pair(*entry);
        const auto eq = pair.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        result.emplace_back(pair.substr(0, eq), pair.substr(eq + 1));
    }
    return result;
}

} // namespace

std::string instanceName(const std::string& argv0) {
    const auto slash = argv0.find_last_of("\\/");
    std::string base = slash == std::string::npos ? argv0 : argv0.substr(slash + 1);
    // Strip .exe (case-insensitive) — otherwise the socket path and config
    // discovery are poisoned with "ybar.exe" (spec section 4).
    if (base.size() > 4) {
        std::string ext = base.substr(base.size() - 4);
        for (auto& c : ext)
            if (c >= 'A' && c <= 'Z') c += 32;
        if (ext == ".exe") base.resize(base.size() - 4);
    }
    return base.empty() ? "ybar" : base;
}

std::vector<std::string> foldTriggerEnvironment(
    std::vector<std::string> argv,
    const std::vector<std::pair<std::string, std::string>>& environment) {
    if (argv.empty() || argv[0] != "--trigger") return argv;
    // AEROSPACE_FOCUSED_WORKSPACE / AEROSPACE_PREV_WORKSPACE fold to the
    // FOCUSED_WORKSPACE / PREV_WORKSPACE keys; every YABAI_* / KOMOREBI_*
    // variable folds to its stripped name. Explicit tokens always win.
    for (const auto& [key, value] : environment) {
        std::string folded;
        if (key == "AEROSPACE_FOCUSED_WORKSPACE") folded = "FOCUSED_WORKSPACE";
        else if (key == "AEROSPACE_PREV_WORKSPACE") folded = "PREV_WORKSPACE";
        else if (key.rfind("YABAI_", 0) == 0) folded = key.substr(6);
        else if (key.rfind("KOMOREBI_", 0) == 0) folded = key.substr(9);
        else continue;
        if (folded.empty() || hasToken(argv, folded + "=")) continue;
        argv.push_back(folded + "=" + value);
    }
    return argv;
}

std::optional<int> runIfClient(const std::vector<std::string>& args, const std::string& instance) {
    if (args.empty()) return std::nullopt; // daemon
    if (args[0] == "--version" || args[0] == "-v") {
        std::printf("ybar %s\n", kVersion);
        return 0;
    }
    if (args[0] == "--help" || args[0] == "-h") {
        std::fputs(kHelp, stdout);
        return 0;
    }
    if (args[0] == "--config" || args[0] == "-c") return std::nullopt; // daemon
    // Local subcommands (autostart, theme) never touch the socket.
    if (const auto exitCode = runLocalVerb(args, instance)) return exitCode;

    std::vector<std::string> message = args;
    if (message[0] == "-m" || message[0] == "--message")
        message.erase(message.begin()); // sketchybar muscle memory
    if (message.empty()) return 0;      // harmless no-op (reference behavior)

    message = foldTriggerEnvironment(std::move(message), processEnvironment());

    const auto path = ybar::ipc::socketPath(instance);
    const auto reply = ybar::ipc::clientSend(path, message);
    if (!reply) {
        std::fprintf(stderr, "[!] could not connect to %s — is the ybar daemon running?\n",
                     path.c_str());
        return 1;
    }
    if (reply->rfind(ybar::ipc::kErrorPrefix, 0) == 0) {
        std::fprintf(stderr, "%s\n", reply->c_str());
        return 1;
    }
    if (!reply->empty()) std::printf("%s\n", reply->c_str());
    return 0;
}

} // namespace ybar::app
