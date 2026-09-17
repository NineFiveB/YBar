// Windows command-line composition. CreateProcessW takes one string, not an
// argv, and the child's CommandLineToArgvW (which is what ybar.exe's own
// main() reads) has quoting rules that a naive "wrap in quotes" gets wrong
// for paths ending in a backslash and for embedded quotes. One implementation,
// shared by the CLI verbs and the ybarw launcher, so the two cannot drift.

#pragma once

#include <string>
#include <vector>

namespace ybar::win {

// Quotes one argument so that CommandLineToArgvW yields it back verbatim.
// Arguments without whitespace or quotes are passed through untouched, which
// keeps command lines readable in Task Manager and the Run key.
std::wstring quoteArgument(const std::wstring& argument);

// `"<exe>" arg1 arg2 ...`. The executable is always quoted: install paths
// routinely contain spaces, and the Run key parses its values as command
// lines.
std::wstring buildCommandLine(const std::wstring& executable,
                              const std::vector<std::wstring>& arguments);

} // namespace ybar::win
