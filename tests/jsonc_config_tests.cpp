// JSONC config tier contract tests (JSONCConfigTests.swift parity) —
// docs/WINDOWS-PORT.md section 3.6.

#include <catch2/catch_test_macros.hpp>

#include "app/jsonc_config.h"

using namespace ybar::app;

TEST_CASE("comments and trailing commas are stripped outside strings") {
    const std::string text = R"({
        // line comment
        "bar": { "height": 32, /* block */ "color": "0xdd1e1e2e", },
        "items": [ { "name": "a", }, ],
    })";
    const auto batches = translateJsonc(text, "test.jsonc");
    REQUIRE_FALSE(batches.empty());
    CHECK(batches[0] == CommandBatch{"--bar", "color=0xdd1e1e2e", "height=32"});
}

TEST_CASE("comment markers inside strings survive") {
    const auto sanitized = sanitizeJsonc(R"({"label": "http://x.test /* not a comment */"})");
    CHECK(sanitized.find("http://x.test") != std::string::npos);
    CHECK(sanitized.find("/* not a comment */") != std::string::npos);
}

TEST_CASE("props emit in sorted order; booleans and numbers stringify per contract") {
    const std::string text = R"({
        "items": [{
            "name": "clock",
            "position": "right",
            "props": { "y_offset": -2, "drawing": true, "update_freq": 20.0, "label": "hi" }
        }]
    })";
    const auto batches = translateJsonc(text, "test.jsonc");
    REQUIRE(batches.size() == 3); // add, set, implicit --update
    CHECK(batches[0] == CommandBatch{"--add", "item", "clock", "right"});
    CHECK(batches[1] == CommandBatch{"--set", "clock", "drawing=on", "label=hi",
                                     "update_freq=20", "y_offset=-2"});
    CHECK(batches[2] == CommandBatch{"--update"});
}

TEST_CASE("events and subscriptions translate one per line") {
    const std::string text = R"({
        "events": ["komorebi_workspace_change"],
        "items": [{ "name": "ws", "subscribe": ["komorebi_workspace_change", "system_woke"] }]
    })";
    const auto batches = translateJsonc(text, "test.jsonc");
    REQUIRE(batches.size() == 4);
    CHECK(batches[0] == CommandBatch{"--add", "event", "komorebi_workspace_change"});
    CHECK(batches[1] == CommandBatch{"--add", "item", "ws", "left"}); // default position
    CHECK(batches[2] ==
          CommandBatch{"--subscribe", "ws", "komorebi_workspace_change", "system_woke"});
}

TEST_CASE("brackets translate with members") {
    const std::string text = R"({
        "items": [{ "name": "widgets", "bracket": ["a", "b"] }]
    })";
    const auto batches = translateJsonc(text, "test.jsonc");
    REQUIRE(batches.size() == 2);
    CHECK(batches[0] == CommandBatch{"--add", "bracket", "widgets", "a", "b"});
}

TEST_CASE("fatal shape errors yield no batches") {
    CHECK(translateJsonc("[1,2,3]", "t.jsonc").empty());          // root not an object
    CHECK(translateJsonc(R"({"bar": []})", "t.jsonc").empty());   // bar not an object
    CHECK(translateJsonc(R"({"items":[{}]})", "t.jsonc").empty()); // item without name
    CHECK(translateJsonc("{nonsense", "t.jsonc").empty());        // parse error
}

TEST_CASE("empty config yields no implicit update") {
    CHECK(translateJsonc("{}", "t.jsonc").empty());
}
