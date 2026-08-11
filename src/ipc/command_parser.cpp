#include "ipc/command_parser.h"

#include <cctype>

namespace ybar::ipc {

namespace {

// "-0.5" is a value, "-abc" is a flag-like terminator.
bool isValue(const std::string& token) {
    return token.size() >= 2 && token[0] == '-' &&
           (std::isdigit(static_cast<unsigned char>(token[1])) || token[1] == '.');
}

} // namespace

std::vector<Batch> parse(const std::vector<std::string>& argv) {
    std::vector<Batch> batches;
    bool collecting = false;
    for (const auto& token : argv) {
        if (token.rfind("--", 0) == 0) {
            batches.push_back(Batch{token.substr(2), {}});
            collecting = true;
        } else if (collecting) {
            if (!token.empty() && token[0] == '-' && !isValue(token)) {
                collecting = false; // terminator itself is dropped
                continue;
            }
            batches.back().args.push_back(token);
        }
        // tokens before the first "--" are silently ignored
    }
    return batches;
}

std::pair<std::string, std::string> keyValue(std::string_view token) {
    const auto eq = token.find('=');
    if (eq == std::string_view::npos) return {std::string(token), std::string()};
    return {std::string(token.substr(0, eq)), std::string(token.substr(eq + 1))};
}

} // namespace ybar::ipc
