// Script execution (spec section 10.1). Resolution order for the interpreter:
// %YBAR_SHELL% -> sh.exe on PATH -> Git for Windows sh.exe located via the
// GitForWindows registry key (Git never adds it to PATH) -> powershell.exe
// -NoProfile.
// Always `<shell> -c <script>` semantics, fire-and-forget, PATH prepended
// with the ybar.exe directory.

#pragma once

#include <map>
#include <string>
#include <vector>

namespace ybar::app {

class ScriptRunner {
public:
    ScriptRunner();

    // Fire-and-forget. env vars overlay the daemon's environment;
    // NAME/SENDER/INFO etc. arrive pre-merged from the event bus.
    void run(const std::string& script, const std::map<std::string, std::string>& env);

    // Runs a config FILE (spec 5): posix shells get the exec-"$0" trick;
    // PowerShell gets `& "<path>"`.
    void runFile(const std::string& path, const std::map<std::string, std::string>& env);

    // The full command line `run(script)` would spawn — used by ybar.exec,
    // which captures stdout itself.
    std::wstring commandLineFor(const std::string& script) const;

    // CreateProcessW environment block (parent env + base env + extras, with
    // the exe directory prepended to PATH) — shared with ybar.exec.
    std::vector<wchar_t> environmentBlock(const std::map<std::string, std::string>& env) const;

    // CONFIG_DIR/BAR_NAME base env + script cwd (the config directory).
    std::map<std::string, std::string> baseEnvironment;
    std::string workingDirectory;

    const std::wstring& shellPath() const { return shell_; }
    bool posix() const { return posix_; }

private:
    void spawn(const std::wstring& commandLine, const std::map<std::string, std::string>& env);

    std::wstring shell_;
    bool posix_ = false;
};

} // namespace ybar::app
