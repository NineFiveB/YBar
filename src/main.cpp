// ybar.exe — daemon and CLI client in one binary (docs/WINDOWS-PORT.md,
// section 5). Role dispatch mirrors the YBar reference implementation:
// empty argv or -c/--config boots the daemon; --help/-h and --version/-v are
// local; everything else is serialized to the instance socket.

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <string>
#include <vector>

#include "app/client.h"
#include "app/daemon.h"

namespace {

// The wire format is UTF-8 (spec 3.1); the ANSI argv would mangle any
// non-ASCII label typed at a console, so take argv from the wide command
// line and convert explicitly.
std::vector<std::string> utf8Arguments(int argc, char** argv) {
    int wideCount = 0;
    LPWSTR* wide = CommandLineToArgvW(GetCommandLineW(), &wideCount);
    if (!wide) return std::vector<std::string>(argv + 1, argv + argc);
    std::vector<std::string> args;
    args.reserve(static_cast<std::size_t>(wideCount > 0 ? wideCount - 1 : 0));
    for (int i = 1; i < wideCount; ++i) {
        const int size =
            WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, nullptr, 0, nullptr, nullptr);
        std::string token(static_cast<std::size_t>(size > 0 ? size - 1 : 0), '\0');
        if (size > 0)
            WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, token.data(), size, nullptr, nullptr);
        args.push_back(std::move(token));
    }
    LocalFree(wide);
    return args;
}

} // namespace

int main(int argc, char** argv) {
    const std::vector<std::string> args = utf8Arguments(argc, argv);
    const std::string instance = ybar::app::instanceName(argc > 0 ? argv[0] : "ybar");

    if (const auto exitCode = ybar::app::runIfClient(args, instance)) return *exitCode;

    std::string configPath;
    for (std::size_t i = 0; i + 1 < args.size(); ++i) {
        if (args[i] == "-c" || args[i] == "--config") configPath = args[i + 1];
    }
    return ybar::app::runDaemon(instance, configPath);
}
