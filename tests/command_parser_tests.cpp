// Tokenizer contract tests ported from the YBar reference suite
// (CoreTests.swift) — docs/WINDOWS-PORT.md section 3.2.

#include <catch2/catch_test_macros.hpp>

#include "ipc/command_parser.h"

using namespace ybar::ipc;

TEST_CASE("splits argv into domain batches") {
    const auto batches = parse({"--animate", "tanh", "30", "--set", "clock", "label=12:00"});
    REQUIRE(batches.size() == 2);
    CHECK(batches[0] == Batch{"animate", {"tanh", "30"}});
    CHECK(batches[1] == Batch{"set", {"clock", "label=12:00"}});
}

TEST_CASE("negative numbers are values, not flags") {
    const auto batches = parse({"--push", "graph", "-0.5", "-1", "-.25"});
    REQUIRE(batches.size() == 1);
    CHECK(batches[0] == Batch{"push", {"graph", "-0.5", "-1", "-.25"}});
}

TEST_CASE("a dash token that is not a number terminates the batch") {
    const auto batches = parse({"--set", "a", "-abc", "b"});
    REQUIRE(batches.size() == 1);
    CHECK(batches[0] == Batch{"set", {"a"}}); // "-abc" dropped, "b" outside any batch
}

TEST_CASE("tokens before the first domain are silently ignored") {
    const auto batches = parse({"junk", "more", "--update"});
    REQUIRE(batches.size() == 1);
    CHECK(batches[0] == Batch{"update", {}});
}

TEST_CASE("empty argv yields no batches") {
    CHECK(parse({}).empty());
}

TEST_CASE("keyValue splits at the first equals sign only") {
    CHECK(keyValue("label=a=b") == std::pair<std::string, std::string>{"label", "a=b"});
    CHECK(keyValue("height=32") == std::pair<std::string, std::string>{"height", "32"});
    CHECK(keyValue("plain") == std::pair<std::string, std::string>{"plain", ""});
    CHECK(keyValue("empty=") == std::pair<std::string, std::string>{"empty", ""});
}
