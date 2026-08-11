// sketchybar-compatible argv wire encoding, byte-identical with the YBar
// reference implementation (docs/WINDOWS-PORT.md, section 3.1):
//
//   frame   = u32 little-endian payload length, then payload (both directions)
//   request = each argv token as UTF-8 bytes + 0x00, then one extra 0x00
//   reply   = raw UTF-8 text; replies starting "[!]" are errors
//
// Payloads above 8 MiB are a protocol error on receive.

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace ybar::ipc {

inline constexpr std::size_t kMaxFrameLength = 8u * 1024u * 1024u;
inline constexpr char kErrorPrefix[] = "[!]";

// argv -> NUL-separated payload with trailing double-NUL.
std::vector<std::uint8_t> encode(const std::vector<std::string>& argv);

// Payload -> argv. Decoding stops at the first empty token, so empty-string
// argv tokens are unrepresentable (reference behavior).
std::vector<std::string> decode(const std::uint8_t* data, std::size_t size);

// u32 LE length prefix + payload.
std::vector<std::uint8_t> frame(const std::vector<std::uint8_t>& payload);

// Reads the 4-byte header; nullopt when the announced length exceeds
// kMaxFrameLength (caller drops the connection).
std::optional<std::uint32_t> frameLength(const std::uint8_t header[4]);

// %LOCALAPPDATA%\ybar\<instance>_<user>.sock (falls back to %TEMP% when the
// path would exceed the 108-byte sun_path limit). The instance name is the
// executable basename with the .exe extension stripped.
std::string socketPath(const std::string& instanceName);

} // namespace ybar::ipc
