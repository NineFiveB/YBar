// Contract tests for the sketchybar-compatible wire format, ported from the
// YBar reference suite (Tests/YBarKitTests/CoreTests.swift). These byte-level
// behaviors are cross-implementation invariants — see docs/WINDOWS-PORT.md
// section 3.1.

#include <algorithm>

#include <catch2/catch_test_macros.hpp>

#include "ipc/wire_format.h"

using namespace ybar::ipc;

TEST_CASE("argv round-trips through encode/decode") {
    const std::vector<std::string> argv = {"--set", "foo", "label=hello world"};
    const auto payload = encode(argv);
    CHECK(decode(payload.data(), payload.size()) == argv);
}

TEST_CASE("encoded payload is NUL-separated with a trailing double NUL") {
    const auto payload = encode({"a", "bc"});
    const std::vector<std::uint8_t> expected = {'a', 0, 'b', 'c', 0, 0};
    CHECK(payload == expected);
}

TEST_CASE("empty argv encodes to a single NUL and decodes to nothing") {
    const auto payload = encode({});
    REQUIRE(payload == std::vector<std::uint8_t>{0});
    CHECK(decode(payload.data(), payload.size()).empty());
}

TEST_CASE("decode stops at the first empty token") {
    // "a" NUL NUL "b" NUL — the double NUL terminates; "b" is unreachable.
    const std::vector<std::uint8_t> payload = {'a', 0, 0, 'b', 0};
    CHECK(decode(payload.data(), payload.size()) == std::vector<std::string>{"a"});
}

TEST_CASE("tokens preserve spaces, equals signs, and UTF-8") {
    const std::vector<std::string> argv = {"--set", "Owner,Window Title",
                                           "label=a=b", "icon=\xF0\x9F\x8D\x89"};
    const auto payload = encode(argv);
    CHECK(decode(payload.data(), payload.size()) == argv);
}

TEST_CASE("frame prefixes a little-endian u32 length") {
    const std::vector<std::uint8_t> payload = {'x', 'y', 'z'};
    const auto framed = frame(payload);
    REQUIRE(framed.size() == payload.size() + 4);
    CHECK(framed[0] == 3);
    CHECK(framed[1] == 0);
    CHECK(framed[2] == 0);
    CHECK(framed[3] == 0);
    CHECK(std::equal(payload.begin(), payload.end(), framed.begin() + 4));
}

TEST_CASE("frameLength reads little-endian and enforces the 8 MiB cap") {
    const std::uint8_t little[4] = {0x01, 0x02, 0x00, 0x00};
    CHECK(frameLength(little) == 0x0201u);

    const std::uint8_t atCap[4] = {0x00, 0x00, 0x80, 0x00}; // 8 MiB exactly
    CHECK(frameLength(atCap) == 8u * 1024u * 1024u);

    const std::uint8_t overCap[4] = {0x01, 0x00, 0x80, 0x00}; // 8 MiB + 1
    CHECK_FALSE(frameLength(overCap).has_value());
}

TEST_CASE("zero-length frames are valid (empty reply)") {
    const std::uint8_t zero[4] = {0, 0, 0, 0};
    CHECK(frameLength(zero) == 0u);
}
