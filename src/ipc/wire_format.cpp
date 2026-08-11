#include "ipc/wire_format.h"

#include <cstdlib>

namespace ybar::ipc {

std::vector<std::uint8_t> encode(const std::vector<std::string>& argv) {
    std::vector<std::uint8_t> payload;
    std::size_t total = 1;
    for (const auto& token : argv) total += token.size() + 1;
    payload.reserve(total);
    for (const auto& token : argv) {
        payload.insert(payload.end(), token.begin(), token.end());
        payload.push_back(0);
    }
    payload.push_back(0);
    return payload;
}

std::vector<std::string> decode(const std::uint8_t* data, std::size_t size) {
    std::vector<std::string> argv;
    std::size_t start = 0;
    for (std::size_t i = 0; i < size; ++i) {
        if (data[i] != 0) continue;
        if (i == start) break; // empty token terminates the payload
        argv.emplace_back(reinterpret_cast<const char*>(data + start), i - start);
        start = i + 1;
    }
    return argv;
}

std::vector<std::uint8_t> frame(const std::vector<std::uint8_t>& payload) {
    const auto length = static_cast<std::uint32_t>(payload.size());
    std::vector<std::uint8_t> framed;
    framed.reserve(payload.size() + 4);
    framed.push_back(static_cast<std::uint8_t>(length & 0xff));
    framed.push_back(static_cast<std::uint8_t>((length >> 8) & 0xff));
    framed.push_back(static_cast<std::uint8_t>((length >> 16) & 0xff));
    framed.push_back(static_cast<std::uint8_t>((length >> 24) & 0xff));
    framed.insert(framed.end(), payload.begin(), payload.end());
    return framed;
}

std::optional<std::uint32_t> frameLength(const std::uint8_t header[4]) {
    const std::uint32_t length = static_cast<std::uint32_t>(header[0]) |
                                 (static_cast<std::uint32_t>(header[1]) << 8) |
                                 (static_cast<std::uint32_t>(header[2]) << 16) |
                                 (static_cast<std::uint32_t>(header[3]) << 24);
    if (length > kMaxFrameLength) return std::nullopt;
    return length;
}

std::string socketPath(const std::string& instanceName) {
    const char* user = std::getenv("USERNAME");
    const std::string fileName = instanceName + "_" + (user ? user : "user") + ".sock";

    if (const char* localAppData = std::getenv("LOCALAPPDATA")) {
        std::string path = std::string(localAppData) + "\\ybar\\" + fileName;
        if (path.size() < 108) return path; // AF_UNIX sun_path limit
    }
    const char* temp = std::getenv("TEMP");
    return std::string(temp ? temp : "C:\\Windows\\Temp") + "\\" + fileName;
}

} // namespace ybar::ipc
