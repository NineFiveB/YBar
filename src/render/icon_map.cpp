#include "render/icon_map.h"


#include <cstdio>
#include <set>
#include <string>

namespace ybar::render {

namespace {

struct Mapping {
    std::string_view name;      // SF Symbol name (or dotted prefix)
    char32_t codepoint;         // Segoe Fluent Icons PUA codepoint
};

// Covers every symbol the shipped themes use plus the common bar vocabulary.
// Sorted by name for readability; lookup is linear (tables this small beat a
// hash map, and this runs once per unique string per font size).
constexpr Mapping kMappings[] = {
    {"airplayaudio", 0xEC15},      {"airplayvideo", 0xEC15},
    {"alarm", 0xE916},             {"antenna.radiowaves.left.and.right", 0xE704},
    {"appletv", 0xE7F4},           {"applewatch", 0xE916},
    {"apps", 0xE71D},              {"arrow.clockwise", 0xE72C},
    {"arrow.down", 0xE74B},        {"arrow.up", 0xE74A},
    {"backward.fill", 0xE892},     {"battery", 0xE83F},
    {"battery.0percent", 0xE850},  {"battery.100percent", 0xE83F},
    {"battery.25percent", 0xE851}, {"battery.50percent", 0xE852},
    {"battery.75percent", 0xE854}, {"bell", 0xEA8F},
    {"bluetooth", 0xE702},         {"bolt", 0xE945},
    {"book", 0xE736},              {"calendar", 0xE787},
    {"camera", 0xE722},            {"chevron.down", 0xE70D},
    {"chevron.left", 0xE76B},      {"chevron.right", 0xE76C},
    {"chevron.up", 0xE70E},        {"clock", 0xE823},
    {"cloud", 0xE753},             {"cpu", 0xE950},
    {"desktopcomputer", 0xE7F4},   {"display", 0xE7F4},
    {"doc", 0xE7C3},               {"envelope", 0xE715},
    {"exclamationmark.triangle", 0xE7BA},
    {"eye", 0xE890},               {"folder", 0xE8B7},
    {"forward.fill", 0xE893},      {"gauge", 0xE9D9},
    {"gearshape", 0xE713},         {"globe", 0xE774},
    {"hammer", 0xE90F},            {"headphones", 0xE7F6},
    {"heart", 0xEB51},             {"house", 0xE80F},
    {"info.circle", 0xE946},       {"keyboard", 0xE765},
    {"laptopcomputer", 0xE7F8},    {"lock", 0xE72E},
    {"macwindow", 0xE737},         {"magnifyingglass", 0xE721},
    {"memorychip", 0xE950},        {"mic", 0xE720},
    {"moon", 0xE708},              {"music.note", 0xEC4F},
    {"network", 0xE968},          {"pause.fill", 0xE769},
    {"person", 0xE77B},            {"photo", 0xEB9F},
    {"play.fill", 0xE768},         {"plus", 0xE710},
    {"power", 0xE7E8},
    {"repeat", 0xE8EE},            {"repeat.1", 0xE8ED},
    {"shuffle", 0xE8B1},           {"speaker.slash", 0xE74F},
    {"speaker.wave.1", 0xE993},    {"speaker.wave.2", 0xE994},
    {"speaker.wave.3", 0xE995},    {"star", 0xE734},
    {"stop.fill", 0xE71A},         {"storefront", 0xE719},
    {"sun.max", 0xE706},           {"terminal", 0xE756},
    {"thermometer", 0xE9CA},       {"trash", 0xE74D},
    {"square.grid.2x2", 0xE71D},   {"volume", 0xE767},
    {"wifi", 0xE701},              {"wifi.slash", 0xEB5E},
    {"wrench", 0xE90F},            {"xmark", 0xE711},
};

constexpr char32_t kPlaceholder = 0xE9CE; // "Unknown" glyph

std::wstring g_iconFont = L"Segoe Fluent Icons";

std::string encodeUtf8(char32_t codepoint) {
    std::string out;
    if (codepoint < 0x80) {
        out.push_back(static_cast<char>(codepoint));
    } else if (codepoint < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (codepoint >> 6)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else if (codepoint < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (codepoint >> 12)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (codepoint >> 18)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    }
    return out;
}

const Mapping* findExact(std::string_view name) {
    for (const auto& mapping : kMappings)
        if (mapping.name == name) return &mapping;
    return nullptr;
}

void warnOnce(std::string_view name) {
    static std::set<std::string> warned;
    if (warned.insert(std::string(name)).second) {
        std::fprintf(stderr,
                     "[ybar] no Windows icon for sf:%.*s — using a placeholder "
                     "(see docs/WINDOWS-PORT.md 7.5)\n",
                     static_cast<int>(name.size()), name.data());
    }
}

} // namespace

std::string_view symbolName(std::string_view text) {
    if (text.size() > 3 && text.compare(0, 3, "sf:") == 0) return text.substr(3);
    if (text.size() > 3 && text.compare(0, 3, "sf.") == 0) return text.substr(3);
    return {};
}

IconGlyph resolveSymbol(std::string_view name) {
    if (name.empty()) return {encodeUtf8(kPlaceholder), false};

    if (const auto* exact = findExact(name)) return {encodeUtf8(exact->codepoint), true};

    // Progressive dotted-prefix fallback: "speaker.wave.2.fill" tries
    // "speaker.wave.2", then "speaker.wave", then "speaker".
    std::string_view prefix = name;
    while (true) {
        const auto dot = prefix.find_last_of('.');
        if (dot == std::string_view::npos) break;
        prefix = prefix.substr(0, dot);
        if (const auto* match = findExact(prefix)) return {encodeUtf8(match->codepoint), true};
    }

    warnOnce(name);
    return {encodeUtf8(kPlaceholder), false};
}

const wchar_t* iconFontFamily() { return g_iconFont.c_str(); }
void setIconFontFamily(const wchar_t* family) { g_iconFont = family; }

} // namespace ybar::render
