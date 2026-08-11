// The daemon shell (spec section 5): a hidden message-only window pumps the
// UI thread; IPC requests marshal from the accept thread via PostMessage and
// a per-request event; a 1 s timer drives update_freq routine ticks.
//
// This slice runs HEADLESS — model + IPC + events, no rendering. Bar surfaces
// attach in the renderer slice.

#pragma once

#include <string>

namespace ybar::app {

// Blocks in the message loop until --exit / WM_ENDSESSION. Returns the
// process exit code. `instance` names the socket; `configPath` is empty when
// no -c was given (config execution lands in a later slice).
int runDaemon(const std::string& instance, const std::string& configPath);

} // namespace ybar::app
