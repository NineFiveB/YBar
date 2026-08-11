// Declarative JSONC config tier (spec section 3.6 / reference JSONCConfig):
// strict JSON + // and /* */ comments (outside strings) + trailing commas,
// translated into the exact command batches the socket takes, followed by an
// implicit --update. Key emission is SORTED (tested contract).

#pragma once

#include <string>
#include <vector>

namespace ybar::app {

using CommandBatch = std::vector<std::string>;

// Parses and translates. Errors go to stderr prefixed "[!] <filename>: ";
// returns an empty list on a fatal parse error.
std::vector<CommandBatch> translateJsonc(const std::string& text, const std::string& filename);

// Exposed for tests: comment/trailing-comma stripping.
std::string sanitizeJsonc(const std::string& text);

} // namespace ybar::app
