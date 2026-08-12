// SF Symbol name -> Windows icon glyph (spec 7.5, decision D11).
//
// The `sf:` / `sf.` GRAMMAR is the contract; the artwork is Apple's and has
// no Windows counterpart, so names resolve to Segoe Fluent Icons codepoints
// (Win11's system icon font, PUA U+E700+) through the table below. Names are
// matched exactly first, then by dotted-prefix (so `battery.75percent` and
// `battery.25percent` share an entry unless one is listed), then by the first
// component. Unmapped names fall back to a placeholder glyph and log once.
//
// Segoe Fluent Icons is preinstalled on Windows 11 but not redistributable;
// the bundled MIT-licensed fluentui-system-icons font is the fallback for
// systems that lack it (resolved at runtime by FontCache).

#pragma once

#include <string>
#include <string_view>

namespace ybar::render {

struct IconGlyph {
    std::string text;   // UTF-8 encoding of the glyph codepoint
    bool mapped = false; // false = placeholder (name not in the table)
};

// `name` is the part after the sf: / sf. prefix.
IconGlyph resolveSymbol(std::string_view name);

// "sf:wifi" -> "wifi"; empty when the string has no sf prefix.
std::string_view symbolName(std::string_view text);

// The icon font family, in preference order: Segoe Fluent Icons (Win11),
// Segoe MDL2 Assets (Win10), then the bundled fallback.
const wchar_t* iconFontFamily();
void setIconFontFamily(const wchar_t* family);

} // namespace ybar::render
