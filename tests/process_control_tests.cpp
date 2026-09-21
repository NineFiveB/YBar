// Process-control grammar and the pure decisions behind `ybar start|stop|
// restart|status` (spec 5). Everything here is argv in, value out: nothing
// launches a bar, writes the Run key, or opens a socket.

#include <catch2/catch_test_macros.hpp>

#include "app/local_verbs.h"
#include "app/process_control.h"
#include "win/command_line.h"

using namespace ybar::app;
using ybar::win::buildCommandLine;
using ybar::win::quoteArgument;

using Kind = ProcessVerb::Kind;

TEST_CASE("bare verbs parse and refuse trailing words") {
    CHECK(parseProcessVerb({"stop"}) == ProcessVerb{Kind::Stop, "", ""});
    CHECK(parseProcessVerb({"status"}) == ProcessVerb{Kind::Status, "", ""});
    CHECK(parseProcessVerb({"stop", "now"}) == ProcessVerb{Kind::Usage, "", "stop"});
    CHECK(parseProcessVerb({"status", "-c", "x"}) == ProcessVerb{Kind::Usage, "", "status"});
}

TEST_CASE("start and restart take an optional -c/--config") {
    CHECK(parseProcessVerb({"start"}) == ProcessVerb{Kind::Start, "", ""});
    CHECK(parseProcessVerb({"start", "-c", "C:\\rc.lua"}) ==
          ProcessVerb{Kind::Start, "C:\\rc.lua", ""});
    CHECK(parseProcessVerb({"restart", "--config", "~/rc.lua"}) ==
          ProcessVerb{Kind::Restart, "~/rc.lua", ""});
    CHECK(parseProcessVerb({"restart"}) == ProcessVerb{Kind::Restart, "", ""});
}

TEST_CASE("a malformed config argument is a usage error, not ignored") {
    CHECK(parseProcessVerb({"start", "rc.lua"}) ==
          ProcessVerb{Kind::Usage, "", "start [-c <path>]"});
    CHECK(parseProcessVerb({"start", "-c"}) == ProcessVerb{Kind::Usage, "", "start [-c <path>]"});
    CHECK(parseProcessVerb({"restart", "-c", "a", "b"}) ==
          ProcessVerb{Kind::Usage, "", "restart [-c <path>]"});
}

TEST_CASE("anything else falls through to the message grammar") {
    CHECK_FALSE(parseProcessVerb({}));
    CHECK_FALSE(parseProcessVerb({"--set", "clock", "label=x"}));
    CHECK_FALSE(parseProcessVerb({"autostart", "enable"}));
    CHECK_FALSE(parseProcessVerb({"theme", "list"}));
    // `-m start` is a message whose first word is "start"; the strip happens
    // after local dispatch, so the verb must not match through it.
    CHECK_FALSE(parseProcessVerb({"-m", "start"}));
    CHECK_FALSE(parseProcessVerb({"Start"}));
}

TEST_CASE("a usage error exits 2, so a wrapper can tell it from a failure") {
    CHECK(runLocalVerb({"stop", "extra"}, "ybar") == 2);
    CHECK(runLocalVerb({"start", "rc.lua"}, "ybar") == 2);
    CHECK(runLocalVerb({"autostart", "bogus"}, "ybar") == 2);
    CHECK(runLocalVerb({"theme", "use"}, "ybar") == 2);
    CHECK(runLocalVerb({"theme", "bogus"}, "ybar") == 2);
    CHECK_FALSE(runLocalVerb({"--query", "bar"}, "ybar").has_value());
}

TEST_CASE("the console is released only when it was created for us") {
    // Explorer / Run key / scheduler: this process is alone on its console.
    CHECK(shouldDetachFromConsole(1, false));
    // A shell is on it too: `ybar` in a terminal runs in that terminal.
    CHECK_FALSE(shouldDetachFromConsole(2, false));
    CHECK_FALSE(shouldDetachFromConsole(3, false));
    // No console at all: already detached (this is the copy `start` made).
    CHECK_FALSE(shouldDetachFromConsole(0, false));
    // YBAR_DEBUG exists to watch the trace, so it keeps even an owned console.
    CHECK_FALSE(shouldDetachFromConsole(1, true));
}

TEST_CASE("the Run value prefers the windowless launcher") {
    const std::filesystem::path exe = L"C:\\Program Files\\ybar\\ybar.exe";
    CHECK(launcherPath(exe) == std::filesystem::path(L"C:\\Program Files\\ybar\\ybarw.exe"));
    CHECK(autostartCommand(exe, true) == L"\"C:\\Program Files\\ybar\\ybarw.exe\"");
    // Without it the value still works, at the price of a console flash.
    CHECK(autostartCommand(exe, false) == L"\"C:\\Program Files\\ybar\\ybar.exe\" start");
}

TEST_CASE("the background log lives in the daemon's state directory") {
    const std::wstring log = daemonLogPath().wstring();
    CHECK(log.size() > 16);
    CHECK(log.substr(log.size() - 16) == L"\\ybar\\stderr.log");
}

TEST_CASE("arguments are quoted the way CommandLineToArgvW unquotes them") {
    CHECK(quoteArgument(L"plain") == L"plain");
    CHECK(quoteArgument(L"") == L"\"\"");
    CHECK(quoteArgument(L"has space") == L"\"has space\"");
    // A path ending in a backslash must not swallow the closing quote.
    CHECK(quoteArgument(L"C:\\dir with space\\") == L"\"C:\\dir with space\\\\\"");
    // An embedded quote is escaped, and backslashes before it doubled.
    CHECK(quoteArgument(L"say \"hi\"") == L"\"say \\\"hi\\\"\"");
    CHECK(quoteArgument(L"a\\\"b") == L"\"a\\\\\\\"b\"");
    // Backslashes elsewhere are literal and left alone.
    CHECK(quoteArgument(L"C:\\a\\b c") == L"\"C:\\a\\b c\"");
}

TEST_CASE("a command line always quotes the executable") {
    CHECK(buildCommandLine(L"C:\\ybar\\ybar.exe", {}) == L"\"C:\\ybar\\ybar.exe\"");
    CHECK(buildCommandLine(L"C:\\ybar\\ybar.exe", {L"-c", L"C:\\my rc\\ybarrc.lua"}) ==
          L"\"C:\\ybar\\ybar.exe\" -c \"C:\\my rc\\ybarrc.lua\"");
}
