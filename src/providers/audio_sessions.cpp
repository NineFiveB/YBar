#include "providers/audio_sessions.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <audioclient.h> // AUDCLNT_S_NO_SINGLE_PROCESS
#include <wrl/client.h>
// clang-format on

#include <algorithm>
#include <cmath>
#include <map>

#include <nlohmann/json.hpp>

#include "providers/app_info.h"

using Microsoft::WRL::ComPtr;

namespace ybar::providers {

namespace {

std::string asciiLower(std::string value) {
    for (auto& c : value)
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + ('a' - 'A'));
    return value;
}

// Lowercase basename minus ".exe" — the group key. ASCII-only lowering is
// fine: the same transform is applied to the set-verb's id argument, so
// matching is consistent regardless of what the path actually contains.
std::string stemFromPath(const std::string& path) {
    std::string stem = path;
    const auto slash = stem.find_last_of("\\/");
    if (slash != std::string::npos) stem = stem.substr(slash + 1);
    if (stem.size() > 4) {
        const std::string tail = asciiLower(stem.substr(stem.size() - 4));
        if (tail == ".exe") stem.resize(stem.size() - 4);
    }
    return asciiLower(stem);
}

// Enumerates the default render endpoint's non-expired sessions and calls
// fn(id, exePath, active, simpleVolume) for each one that resolves to a
// well-defined group id. Everything COM is released on return.
template <typename Fn>
void forEachSession(Fn&& fn) {
    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&enumerator))))
        return;
    ComPtr<IMMDevice> device;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device)))
        return; // headless session / CI runner: no endpoint, no sessions
    ComPtr<IAudioSessionManager2> manager;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_INPROC_SERVER, nullptr,
                                reinterpret_cast<void**>(manager.GetAddressOf()))))
        return;
    ComPtr<IAudioSessionEnumerator> sessions;
    if (FAILED(manager->GetSessionEnumerator(&sessions))) return;
    int count = 0;
    if (FAILED(sessions->GetCount(&count))) return;

    for (int i = 0; i < count; ++i) {
        ComPtr<IAudioSessionControl> control;
        if (FAILED(sessions->GetSession(i, &control))) continue;
        ComPtr<IAudioSessionControl2> control2;
        if (FAILED(control.As(&control2))) continue;

        AudioSessionState state = AudioSessionStateInactive;
        if (FAILED(control2->GetState(&state)) || state == AudioSessionStateExpired) continue;

        ComPtr<ISimpleAudioVolume> volume;
        if (FAILED(control.As(&volume))) continue;

        // S_OK means system sounds; S_FALSE means an app session — a
        // SUCCEEDED() test would lump every session into "system".
        if (control2->IsSystemSoundsSession() == S_OK) {
            fn(std::string("system"), std::string(), state == AudioSessionStateActive,
               volume.Get());
            continue;
        }

        DWORD pid = 0;
        // AUDCLNT_S_NO_SINGLE_PROCESS is a SUCCESS code (cross-process
        // session) that still writes a representative pid — gate on FAILED,
        // not on hr != S_OK.
        if (FAILED(control2->GetProcessId(&pid)) || pid == 0) continue;

        // Unreadable image path (SYSTEM-owned process, or the pid died while
        // the session is still merely Inactive): skip the session. Merging
        // every unreadable session under an empty stem would hand one slider
        // a grab-bag of unrelated processes.
        const std::string path = executablePathForProcess(pid);
        if (path.empty()) continue;

        fn(stemFromPath(path), path, state == AudioSessionStateActive, volume.Get());
    }
}

// Muted -> 0, matching the master percentFrom convention. The scalar is
// relative to the master volume (100 = follow master) — the Windows 11
// Settings mixer convention, not SndVol's absolute clamp.
int percentFrom(ISimpleAudioVolume* volume) {
    if (!volume) return 0;
    BOOL muted = FALSE;
    if (SUCCEEDED(volume->GetMute(&muted)) && muted) return 0;
    float scalar = 0;
    if (FAILED(volume->GetMasterVolume(&scalar))) return 0;
    return static_cast<int>(std::lround(scalar * 100.0f));
}

} // namespace

std::vector<AudioSessionGroup> audioSessionGroups() {
    std::map<std::string, AudioSessionGroup> byId;
    forEachSession([&](const std::string& id, const std::string& path, bool active,
                       ISimpleAudioVolume* volume) {
        auto [it, inserted] = byId.try_emplace(id);
        auto& group = it->second;
        if (inserted) {
            group.id = id;
            group.exePath = path;
            group.name = id == "system" ? "System sounds" : appNameForExecutablePath(path);
            group.muted = true; // muted = ALL sessions muted; &= below
        }
        BOOL muted = FALSE;
        group.muted = group.muted && SUCCEEDED(volume->GetMute(&muted)) && muted;
        // max across the group's sessions: any single number for N sessions
        // is a compromise, and the loudest one is the least surprising.
        group.volume = std::max(group.volume, percentFrom(volume));
        group.active = group.active || active;
    });

    std::vector<AudioSessionGroup> groups;
    groups.reserve(byId.size());
    for (auto& [id, group] : byId) groups.push_back(std::move(group));
    std::sort(groups.begin(), groups.end(),
              [](const AudioSessionGroup& a, const AudioSessionGroup& b) {
                  if ((a.id == "system") != (b.id == "system")) return b.id == "system";
                  const auto an = asciiLower(a.name), bn = asciiLower(b.name);
                  if (an != bn) return an < bn;
                  return a.id < b.id;
              });
    return groups;
}

std::string serializeAudioSessionGroups(const std::vector<AudioSessionGroup>& groups) {
    nlohmann::json out = nlohmann::json::array();
    for (const auto& group : groups)
        out.push_back({{"id", group.id},
                       {"name", group.name},
                       {"path", group.exePath},
                       {"volume", group.volume},
                       {"muted", group.muted},
                       {"active", group.active}});
    return out.dump(2);
}

bool setAudioSessionVolume(const std::string& id, int percent) {
    const std::string wanted = asciiLower(id);
    const int clamped = std::min(100, std::max(0, percent));
    bool matched = false;
    bool ok = true;
    forEachSession([&](const std::string& sessionId, const std::string&, bool,
                       ISimpleAudioVolume* volume) {
        if (sessionId != wanted) return;
        matched = true;
        if (clamped == 0) {
            // Mute keeping the scalar, so a later unmute restores the level —
            // and the mute's HRESULT counts, mirroring the master path.
            ok = SUCCEEDED(volume->SetMute(TRUE, nullptr)) && ok;
            return;
        }
        // Scalar before unmute so a muted session cannot blip its old level;
        // the unmute itself is best-effort, mirroring the master path.
        if (FAILED(volume->SetMasterVolume(static_cast<float>(clamped) / 100.0f, nullptr))) {
            ok = false;
            return;
        }
        volume->SetMute(FALSE, nullptr);
    });
    return matched && ok;
}

} // namespace ybar::providers
