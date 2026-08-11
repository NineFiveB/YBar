// Script execution (spec section 10.1). Resolution order for the interpreter:
// %YBAR_SHELL% -> sh.exe on PATH (Git Bash) -> powershell.exe -NoProfile.
// Always `<shell> -c <script>` semantics, fire-and-forget, PATH prepended
// with the ybar.exe directory.

#pragma once

#include <map>
#include <string>

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
