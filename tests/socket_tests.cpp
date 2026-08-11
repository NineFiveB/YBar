// End-to-end AF_UNIX transport tests — a real server/client round trip over
// the Winsock socket on the CI runner (spec sections 3.1, 5.1).

#include <algorithm>
#include <cstdlib>
#include <utility>

#include <catch2/catch_test_macros.hpp>

#include "app/client.h"
#include "ipc/socket.h"

using namespace ybar::ipc;

namespace {

std::string tempSocketPath(const char* name) {
    const char* temp = std::getenv("TEMP");
    return std::string(temp ? temp : ".") + "\\ybar_test_" + name + ".sock";
}

} // namespace

TEST_CASE("server and client round-trip framed argv over AF_UNIX") {
    SocketServer server;
    const auto path = tempSocketPath("roundtrip");
    std::vector<std::string> received;
    const auto error = server.start(path, [&](const std::vector<std::string>& argv) {
        received = argv;
        return std::string("pong");
    });
    REQUIRE_FALSE(error);

    const auto reply = clientSend(path, {"--ping", "with space", "eq=a=b"});
    REQUIRE(reply);
    CHECK(*reply == "pong");
    CHECK(received == std::vector<std::string>{"--ping", "with space", "eq=a=b"});
    server.stop();
}

TEST_CASE("empty replies arrive as empty strings") {
    SocketServer server;
    const auto path = tempSocketPath("empty");
    REQUIRE_FALSE(server.start(path, [](const auto&) { return std::string(); }));
    const auto reply = clientSend(path, {"--update"});
    REQUIRE(reply);
    CHECK(reply->empty());
    server.stop();
}

TEST_CASE("a second server on the same path refuses to start while the first lives") {
    SocketServer first;
    const auto path = tempSocketPath("lock");
    REQUIRE_FALSE(first.start(path, [](const auto&) { return std::string("pong"); }));

    SocketServer second;
    const auto error = second.start(path, [](const auto&) { return std::string("pong"); });
    REQUIRE(error);
    CHECK(error->find("already running") != std::string::npos);
    first.stop();

    // After the first stops, the path is free again (stale-file rebind).
    SocketServer third;
    REQUIRE_FALSE(third.start(path, [](const auto&) { return std::string("pong"); }));
    third.stop();
}

TEST_CASE("client reports transport failure for a dead socket") {
    CHECK_FALSE(clientSend(tempSocketPath("nobody"), {"--ping"}, 0.5));
}

TEST_CASE("instance name strips the exe extension") {
    using ybar::app::instanceName;
    CHECK(instanceName("C:\\Tools\\ybar.exe") == "ybar");
    CHECK(instanceName("ybar.EXE") == "ybar");
    CHECK(instanceName("/usr/bin/ybar") == "ybar");
    CHECK(instanceName("ybar2.exe") == "ybar2"); // renamed = independent instance
}

TEST_CASE("trigger env folding adds workspace keys without clobbering") {
    using ybar::app::foldTriggerEnvironment;
    const std::vector<std::pair<std::string, std::string>> env = {
        {"AEROSPACE_FOCUSED_WORKSPACE", "3"},
        {"KOMOREBI_FOCUSED_WORKSPACE", "V"},
        {"YABAI_SPACE_ID", "7"},
        {"UNRELATED", "x"},
    };

    auto folded = foldTriggerEnvironment({"--trigger", "ws_change"}, env);
    CHECK(std::find(folded.begin(), folded.end(), "FOCUSED_WORKSPACE=3") != folded.end());
    CHECK(std::find(folded.begin(), folded.end(), "SPACE_ID=7") != folded.end());
    // KOMOREBI_FOCUSED_WORKSPACE folds to FOCUSED_WORKSPACE — already present
    // from the AeroSpace fold, so it must not be duplicated or clobbered.
    CHECK(std::count_if(folded.begin(), folded.end(), [](const std::string& t) {
              return t.rfind("FOCUSED_WORKSPACE=", 0) == 0;
          }) == 1);
    CHECK(std::find(folded.begin(), folded.end(), "UNRELATED=x") == folded.end());

    // Explicit tokens win over env folding.
    auto explicitToken =
        foldTriggerEnvironment({"--trigger", "ws_change", "FOCUSED_WORKSPACE=9"}, env);
    CHECK(std::count_if(explicitToken.begin(), explicitToken.end(), [](const std::string& t) {
              return t.rfind("FOCUSED_WORKSPACE=", 0) == 0;
          }) == 1);
    CHECK(std::find(explicitToken.begin(), explicitToken.end(), "FOCUSED_WORKSPACE=9") !=
          explicitToken.end());

    // Non-trigger messages are never touched.
    CHECK(foldTriggerEnvironment({"--set", "a", "b=1"}, env) ==
          std::vector<std::string>{"--set", "a", "b=1"});
}
