// CLI client role (spec sections 3.2, 5, 9): role dispatch, -m stripping,
// AEROSPACE_*/YABAI_*/KOMOREBI_* env folding on --trigger, and the
// [!]-to-stderr/exit-1 reply convention.

#pragma once

#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace ybar::app {

// Executable basename with the .exe extension stripped — renaming the binary
// yields an independent instance (own socket, own config).
std::string instanceName(const std::string& argv0);

// Returns an exit code when the process acted as a client (or handled
// --help/--version); nullopt means "run the daemon".
std::optional<int> runIfClient(const std::vector<std::string>& args,
                               const std::string& instance);

// Exposed for tests: env folding applied to a --trigger message.
std::vector<std::string> foldTriggerEnvironment(
    std::vector<std::string> argv,
    const std::vector<std::pair<std::string, std::string>>& environment);

} // namespace ybar::app
