#include "providers/app_info.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winver.h> // WIN32_LEAN_AND_MEAN drops the version API otherwise
// clang-format on

#include <vector>

namespace ybar::providers {

namespace {

std::string narrow(const std::wstring& wide) {
    if (wide.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                         static_cast<int>(wide.size()), nullptr, 0, nullptr,
                                         nullptr);
    std::string out(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), out.data(),
                        size, nullptr, nullptr);
    return out;
}

std::wstring baseNameWithoutExe(const std::wstring& path) {
    std::wstring name = path;
    const auto slash = name.find_last_of(L"\\/");
    if (slash != std::wstring::npos) name = name.substr(slash + 1);
    if (name.size() > 4) {
        const std::wstring tail = name.substr(name.size() - 4);
        if (_wcsicmp(tail.c_str(), L".exe") == 0) name.resize(name.size() - 4);
    }
    return name;
}

// FileDescription from the version resource — what Explorer shows in the
// Description column, and the closest analogue to localizedName.
std::wstring fileDescription(const std::wstring& path) {
    DWORD ignored = 0;
    const DWORD size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
    if (size == 0) return {};
    std::vector<unsigned char> buffer(size);
    if (!GetFileVersionInfoW(path.c_str(), 0, size, buffer.data())) return {};

    struct LangCodePage {
        WORD language;
        WORD codePage;
    };
    LangCodePage* translations = nullptr;
    UINT translationBytes = 0;
    if (!VerQueryValueW(buffer.data(), L"\\VarFileInfo\\Translation",
                        reinterpret_cast<void**>(&translations), &translationBytes) ||
        translationBytes < sizeof(LangCodePage))
        return {};

    const UINT count = translationBytes / sizeof(LangCodePage);
    for (UINT i = 0; i < count; ++i) {
        wchar_t key[64];
        swprintf_s(key, L"\\StringFileInfo\\%04x%04x\\FileDescription",
                   translations[i].language, translations[i].codePage);
        wchar_t* value = nullptr;
        UINT valueLength = 0;
        if (VerQueryValueW(buffer.data(), key, reinterpret_cast<void**>(&value), &valueLength) &&
            value && valueLength > 1) {
            std::wstring description(value, valueLength - 1); // trim the NUL
            while (!description.empty() && description.back() == L'\0') description.pop_back();
            if (!description.empty()) return description;
        }
    }
    return {};
}

std::wstring imagePathForProcess(DWORD processId) {
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId);
    if (!process) return {};
    wchar_t path[MAX_PATH];
    DWORD size = MAX_PATH;
    std::wstring result;
    if (QueryFullProcessImageNameW(process, 0, path, &size)) result.assign(path, size);
    CloseHandle(process);
    return result;
}

struct FrameHostSearch {
    DWORD hostProcessId = 0;
    DWORD childProcessId = 0;
};

BOOL CALLBACK findHostedChild(HWND child, LPARAM param) {
    auto* search = reinterpret_cast<FrameHostSearch*>(param);
    DWORD processId = 0;
    GetWindowThreadProcessId(child, &processId);
    if (processId != 0 && processId != search->hostProcessId) {
        search->childProcessId = processId;
        return FALSE;
    }
    return TRUE;
}

} // namespace

std::string appNameForExecutablePath(const std::string& path) {
    if (path.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, path.c_str(),
                                         static_cast<int>(path.size()), nullptr, 0);
    std::wstring wide(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, path.c_str(), static_cast<int>(path.size()), wide.data(),
                        size);
    std::wstring description = fileDescription(wide);
    if (description.empty()) description = baseNameWithoutExe(wide);
    return narrow(description);
}

std::string appNameForProcess(unsigned long processId) {
    const std::wstring path = imagePathForProcess(static_cast<DWORD>(processId));
    if (path.empty()) return {};
    std::wstring description = fileDescription(path);
    if (description.empty()) description = baseNameWithoutExe(path);
    return narrow(description);
}

std::string appNameForWindow(void* hwndValue) {
    const HWND hwnd = static_cast<HWND>(hwndValue);
    if (!hwnd) return {};
    DWORD processId = 0;
    GetWindowThreadProcessId(hwnd, &processId);
    if (processId == 0) return {};

    // UWP apps run inside ApplicationFrameHost; the real app owns a child
    // CoreWindow in a different process (spec 10).
    const std::wstring path = imagePathForProcess(processId);
    if (_wcsicmp(baseNameWithoutExe(path).c_str(), L"ApplicationFrameHost") == 0) {
        FrameHostSearch search{processId, 0};
        EnumChildWindows(hwnd, findHostedChild, reinterpret_cast<LPARAM>(&search));
        if (search.childProcessId != 0) {
            const std::string hosted = appNameForProcess(search.childProcessId);
            if (!hosted.empty()) return hosted;
        }
    }
    return appNameForProcess(processId);
}

} // namespace ybar::providers
