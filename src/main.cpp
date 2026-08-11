// ybar.exe — daemon and CLI client in one binary (docs/WINDOWS-PORT.md, section 5).
//
// Role dispatch mirrors the YBar reference implementation (ybar/main.swift):
// empty argv boots the daemon; --config/-c falls through to the daemon;
// --help/-h and --version/-v are handled locally; anything else is serialized
// to the instance socket as a client message.

#include <cstdio>
#include <string>
#include <vector>

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
    "Design: docs/WINDOWS-PORT.md\n";

} // namespace

int main(int argc, char** argv) {
    std::vector<std::string> args(argv + 1, argv + argc);

    if (!args.empty() && (args[0] == "--version" || args[0] == "-v")) {
        std::printf("ybar %s\n", kVersion);
        return 0;
    }
    if (!args.empty() && (args[0] == "--help" || args[0] == "-h")) {
        std::fputs(kHelp, stdout);
        return 0;
    }

    // TODO(W1): client role — strip a leading -m/--message, fold
    //           AEROSPACE_*/YABAI_*/KOMOREBI_* env vars into --trigger argv,
    //           frame with ipc::encode/ipc::frame, send over the instance
    //           socket, print the reply ([!] prefix -> stderr, exit 1).
    // TODO(W1): daemon role — instance lock via socket ping, message-only
    //           window + bar surfaces, providers, IPC accept thread, config
    //           discovery and execution, GetMessage loop.
    std::fprintf(stderr, "[!] ybar-win is a skeleton — daemon and client are not implemented yet\n");
    return 1;
}
