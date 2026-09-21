#include "win/command_line.h"

namespace ybar::win {

std::wstring quoteArgument(const std::wstring& argument) {
    const bool needsQuotes =
        argument.empty() || argument.find_first_of(L" \t\n\v\"") != std::wstring::npos;
    if (!needsQuotes) return argument;

    // The rules CommandLineToArgvW inverts (Microsoft, "Parsing C++ command-
    // line arguments"): backslashes are literal unless they precede a quote,
    // in which case each pair is one backslash and an odd trailing one escapes
    // the quote. So backslashes before an embedded quote — and before the
    // closing quote — are doubled, and an embedded quote gets one more.
    std::wstring quoted = L"\"";
    std::size_t backslashes = 0;
    for (const wchar_t c : argument) {
        if (c == L'\\') {
            ++backslashes;
            continue;
        }
        if (c == L'"') {
            quoted.append(backslashes * 2 + 1, L'\\');
            quoted.push_back(L'"');
        } else {
            quoted.append(backslashes, L'\\');
            quoted.push_back(c);
        }
        backslashes = 0;
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'"');
    return quoted;
}

std::wstring buildCommandLine(const std::wstring& executable,
                              const std::vector<std::wstring>& arguments) {
    std::wstring line = L"\"" + executable + L"\"";
    for (const auto& argument : arguments) {
        line.push_back(L' ');
        line.append(quoteArgument(argument));
    }
    return line;
}

} // namespace ybar::win
