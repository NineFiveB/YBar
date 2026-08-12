// Shared input helpers: the modifier-name contract and the "is the pointer
// over any ybar window" test the global mouse events need.

#pragma once

namespace ybar::win {

// Priority order shift > ctrl > alt > cmd(Win), else "none" — contract
// (spec 3.5), identical to the reference's modifierName.
const char* currentModifier();

// Same contract, but reading the ASYNCHRONOUS key state. GetKeyState reports
// the calling thread's snapshot, which is stale on a message-only window that
// never has keyboard focus — the global modifier_change path must use this.
const char* currentModifierAsync();

// True when the given screen point sits over a ybar bar or popup window.
// The union across every ybar window is what mouse.entered.global /
// mouse.exited.global are defined over (spec 3.4).
bool pointOverYBarWindow(int screenX, int screenY);

} // namespace ybar::win
