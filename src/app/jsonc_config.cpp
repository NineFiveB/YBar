#include "app/jsonc_config.h"

#include <cmath>
#include <cstdio>

#include <nlohmann/json.hpp>

namespace ybar::app {

using nlohmann::json;

namespace {

void warn(const std::string& filename, const std::string& message) {
    std::fprintf(stderr, "[!] %s: %s\n", filename.c_str(), message.c_str());
}

// Booleans -> on/off; integral numbers (|x| < 1e15) without ".0"; strings
// pass through (reference stringification contract).
std::string valueString(const json& value) {
    if (value.is_boolean()) return value.get<bool>() ? "on" : "off";
    if (value.is_string()) return value.get<std::string>();
    if (value.is_number_integer() || value.is_number_unsigned())
        return std::to_string(value.get<long long>());
    if (value.is_number_float()) {
        const double number = value.get<double>();
        if (std::abs(number) < 1e15 && number == std::floor(number))
            return std::to_string(static_cast<long long>(number));
        char buffer[64];
        std::snprintf(buffer, sizeof(buffer), "%g", number);
        return buffer;
    }
    return {};
}

bool scalarProps(const json& object, const std::string& context, const std::string& filename,
                 std::vector<std::string>& out) {
    for (const auto& [key, value] : object.items()) { // nlohmann objects iterate sorted
        if (!value.is_primitive() || value.is_null()) {
            warn(filename, context + "." + key + ": value must be a string, number, or boolean");
            return false;
        }
        out.push_back(key + "=" + valueString(value));
    }
    return true;
}

} // namespace

std::string sanitizeJsonc(const std::string& text) {
    std::string out;
    out.reserve(text.size());
    bool inString = false;
    bool escaped = false;
    for (std::size_t i = 0; i < text.size(); ++i) {
        const char c = text[i];
        if (inString) {
            out.push_back(c);
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') inString = false;
            continue;
        }
        if (c == '"') {
            inString = true;
            out.push_back(c);
            continue;
        }
        if (c == '/' && i + 1 < text.size() && text[i + 1] == '/') {
            while (i < text.size() && text[i] != '\n') ++i;
            if (i < text.size()) out.push_back('\n');
            continue;
        }
        if (c == '/' && i + 1 < text.size() && text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.size() && !(text[i] == '*' && text[i + 1] == '/')) ++i;
            ++i; // tolerate an unterminated block comment
            continue;
        }
        if (c == ',') {
            // Trailing comma: skip when the next non-whitespace is } or ].
            std::size_t j = i + 1;
            while (j < text.size() &&
                   (text[j] == ' ' || text[j] == '\t' || text[j] == '\r' || text[j] == '\n'))
                ++j;
            if (j < text.size() && (text[j] == '}' || text[j] == ']')) continue;
        }
        out.push_back(c);
    }
    return out;
}

std::vector<CommandBatch> translateJsonc(const std::string& text, const std::string& filename) {
    std::vector<CommandBatch> batches;
    json root;
    try {
        root = json::parse(sanitizeJsonc(text));
    } catch (const json::exception& error) {
        warn(filename, std::string("parse error: ") + error.what());
        return {};
    }
    if (!root.is_object()) {
        warn(filename, "root must be an object");
        return {};
    }

    if (root.contains("bar")) {
        if (!root["bar"].is_object()) {
            warn(filename, "\"bar\" must be an object");
            return {};
        }
        CommandBatch batch{"--bar"};
        if (!scalarProps(root["bar"], "bar", filename, batch)) return {};
        if (batch.size() > 1) batches.push_back(std::move(batch));
    }
    if (root.contains("defaults")) {
        if (!root["defaults"].is_object()) {
            warn(filename, "\"defaults\" must be an object");
            return {};
        }
        CommandBatch batch{"--default"};
        if (!scalarProps(root["defaults"], "defaults", filename, batch)) return {};
        if (batch.size() > 1) batches.push_back(std::move(batch));
    }
    if (root.contains("events")) {
        if (!root["events"].is_array()) {
            warn(filename, "\"events\" must be an array of strings");
            return {};
        }
        for (const auto& event : root["events"]) {
            if (!event.is_string()) {
                warn(filename, "\"events\" must be an array of strings");
                return {};
            }
            batches.push_back({"--add", "event", event.get<std::string>()});
        }
    }
    if (root.contains("items")) {
        if (!root["items"].is_array()) {
            warn(filename, "\"items\" must be an array");
            return {};
        }
        int index = 0;
        for (const auto& item : root["items"]) {
            const std::string context = "items[" + std::to_string(index++) + "]";
            if (!item.is_object()) {
                warn(filename, context + " must be an object");
                return {};
            }
            const std::string name = item.value("name", std::string());
            if (name.empty()) {
                warn(filename, context + " needs a \"name\"");
                return {};
            }
            if (item.contains("bracket")) {
                if (!item["bracket"].is_array() || item["bracket"].empty()) {
                    warn(filename, context + ".bracket must be a non-empty array of member names");
                    return {};
                }
                CommandBatch batch{"--add", "bracket", name};
                for (const auto& member : item["bracket"])
                    batch.push_back(member.get<std::string>());
                batches.push_back(std::move(batch));
            } else {
                batches.push_back({"--add", "item", name, item.value("position", "left")});
            }
            if (item.contains("props")) {
                if (!item["props"].is_object()) {
                    warn(filename, context + ".props must be an object");
                    return {};
                }
                CommandBatch batch{"--set", name};
                if (!scalarProps(item["props"], context, filename, batch)) return {};
                if (batch.size() > 2) batches.push_back(std::move(batch));
            }
            if (item.contains("subscribe")) {
                if (!item["subscribe"].is_array() || item["subscribe"].empty()) {
                    warn(filename, context + ".subscribe must be a non-empty array of event names");
                    return {};
                }
                CommandBatch batch{"--subscribe", name};
                for (const auto& event : item["subscribe"])
                    batch.push_back(event.get<std::string>());
                batches.push_back(std::move(batch));
            }
            for (const auto& [key, value] : item.items()) {
                (void)value;
                if (key != "name" && key != "bracket" && key != "position" && key != "props" &&
                    key != "subscribe") {
                    std::fprintf(stderr,
                                 "[?] jsonc: %s: unknown key \"%s\" (expected "
                                 "name/bracket/position/props/subscribe)\n",
                                 context.c_str(), key.c_str());
                }
            }
        }
    }
    for (const auto& [key, value] : root.items()) {
        (void)value;
        if (key != "bar" && key != "defaults" && key != "events" && key != "items") {
            std::fprintf(stderr,
                         "[?] jsonc: unknown top-level key \"%s\" (expected "
                         "bar/defaults/events/items)\n",
                         key.c_str());
        }
    }

    if (!batches.empty()) batches.push_back({"--update"}); // boot population
    return batches;
}

} // namespace ybar::app
