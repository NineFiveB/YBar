#include "app/platform.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <cstdlib>

namespace ybar::app {

namespace fs = std::filesystem;

std::wstring widen(const std::string& text) {
    if (text.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                         static_cast<int>(text.size()), nullptr, 0);
    std::wstring wide(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), wide.data(),
                        size);
    return wide;
}

std::string narrow(const std::wstring& wide) {
    if (wide.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                         static_cast<int>(wide.size()), nullptr, 0, nullptr,
                                         nullptr);
    std::string text(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), text.data(),
                        size, nullptr, nullptr);
    return text;
}

fs::path executablePath() {
    wchar_t buffer[MAX_PATH];
    const DWORD n = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    std::wstring path(buffer, n);
    const HANDLE file = CreateFileW(path.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
        wchar_t resolved[1024];
        const DWORD length = GetFinalPathNameByHandleW(file, resolved, 1024, FILE_NAME_NORMALIZED);
        CloseHandle(file);
        if (length > 0 && length < 1024) {
            std::wstring final(resolved, length);
            // \\?\UNC\server\share -> \\server\share; \\?\C:\... -> C:\...
            if (final.rfind(LR"(\\?\UNC\)", 0) == 0) final = L"\\\\" + final.substr(8);
            else if (final.rfind(LR"(\\?\)", 0) == 0) final = final.substr(4);
            path = final;
        }
    }
    return fs::path(path);
}

namespace {

fs::path environmentPath(const wchar_t* name) {
    wchar_t* value = nullptr;
    std::size_t length = 0;
    if (_wdupenv_s(&value, &length, name) != 0 || !value) return {};
    fs::path path(value);
    free(value);
    return path;
}

} // namespace

fs::path configDirectory() {
    const fs::path profile = environmentPath(L"USERPROFILE");
    return profile.empty() ? fs::path{} : profile / L".config" / L"ybar";
}

fs::path stateDirectory() {
    if (const fs::path local = environmentPath(L"LOCALAPPDATA"); !local.empty())
        return local / L"ybar";
    const fs::path temp = environmentPath(L"TEMP");
    return temp.empty() ? fs::path(L"C:\\Windows\\Temp") : temp;
}

} // namespace ybar::app
