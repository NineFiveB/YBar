// System appearance the bar tracks so it matches Windows' flat/transparent
// choice (docs/WINDOWS-PORT.md 7.6). Header-only: a single registry read with
// no state, shared by the bar surface, popup surface, and the daemon's popup
// scene build — none of which want a translation unit for one query.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

namespace ybar::win {

// Windows "Transparency effects" (Settings > Personalization > Colors). When
// off, the shell renders Acrylic/Mica as a solid fallback and flyouts stop
// showing through — the bar follows suit: no DWM Acrylic, and popup panels
// composite opaque. Absent value defaults to on (the OS default).
inline bool systemTransparencyEnabled() {
    DWORD value = 1;
    DWORD size = sizeof(value);
    if (RegGetValueW(HKEY_CURRENT_USER,
                     L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"EnableTransparency", RRF_RT_REG_DWORD, nullptr, &value,
                     &size) == ERROR_SUCCESS)
        return value != 0;
    return true;
}

} // namespace ybar::win
