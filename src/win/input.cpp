#include "win/input.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <wchar.h>

namespace ybar::win {

const char* currentModifier() {
    if (GetKeyState(VK_SHIFT) < 0) return "shift";
    if (GetKeyState(VK_CONTROL) < 0) return "ctrl";
    if (GetKeyState(VK_MENU) < 0) return "alt";
    if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) return "cmd";
    return "none";
}

const char* currentModifierAsync() {
    if (GetAsyncKeyState(VK_SHIFT) < 0) return "shift";
    if (GetAsyncKeyState(VK_CONTROL) < 0) return "ctrl";
    if (GetAsyncKeyState(VK_MENU) < 0) return "alt";
    if (GetAsyncKeyState(VK_LWIN) < 0 || GetAsyncKeyState(VK_RWIN) < 0) return "cmd";
    return "none";
}

bool pointOverYBarWindow(int screenX, int screenY) {
    const POINT point{screenX, screenY};
    const HWND target = WindowFromPoint(point);
    const HWND root = target ? GetAncestor(target, GA_ROOT) : nullptr;
    if (!root) return false;
    wchar_t className[32] = L"";
    if (!GetClassNameW(root, className, 32)) return false;
    return wcscmp(className, L"ybar.bar") == 0 || wcscmp(className, L"ybar.popup") == 0;
}

} // namespace ybar::win
