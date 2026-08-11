// ybar.exe — daemon and CLI client in one binary (docs/WINDOWS-PORT.md,
// section 5). Role dispatch mirrors the YBar reference implementation:
// empty argv or -c/--config boots the daemon; --help/-h and --version/-v are
// local; everything else is serialized to the instance socket.

#include <string>
#include <vector>

#include "app/client.h"
#include "app/daemon.h"

int main(int argc, char** argv) {
    std::vector<std::string> args(argv + 1, argv + argc);
    const std::string instance = ybar::app::instanceName(argc > 0 ? argv[0] : "ybar");

    if (const auto exitCode = ybar::app::runIfClient(args, instance)) return *exitCode;

    std::string configPath;
    for (std::size_t i = 0; i + 1 < args.size(); ++i) {
        if (args[i] == "-c" || args[i] == "--config") configPath = args[i + 1];
    }
    return ybar::app::runDaemon(instance, configPath);
}
