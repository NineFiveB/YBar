// Domain-batch tokenizer for the sketchybar-compatible message grammar
// (docs/WINDOWS-PORT.md, section 3.2). One client message can carry many
// batches: "--animate tanh 30 --set clock label.color=0xffff0000".

#pragma once

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace ybar::ipc {

// One "--<domain> <args...>" batch.
struct Batch {
    std::string domain; // without the leading "--"
    std::vector<std::string> args;

    bool operator==(const Batch&) const = default;
};

// Splits argv into domain batches. "--word" opens a batch; following tokens
// are its args until the next "-"-prefixed token — EXCEPT negative numbers
// ("-" followed by a digit or '.'), which stay args (--push graph -0.5).
// Tokens outside any batch are silently ignored (reference behavior).
std::vector<Batch> parse(const std::vector<std::string>& argv);

// Splits "key=value" at the FIRST '='; values may contain '='.
// A token without '=' yields {token, ""}.
std::pair<std::string, std::string> keyValue(std::string_view token);

} // namespace ybar::ipc
