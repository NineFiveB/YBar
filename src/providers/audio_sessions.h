// Per-app audio sessions (spec 10, Audio row) — Windows extension with no
// macOS counterpart (CoreAudio has no public per-app volume; the reference
// AudioProvider.swift is device-level only).
//
// Deliberately STATELESS, the tray_icons pattern: every call re-activates
// IAudioSessionManager2 on the default render endpoint, enumerates, and
// releases everything before returning. That trades a few milliseconds per
// call for the entire IAudioSessionNotification / IAudioSessionEvents
// lifetime surface (registration quirks, per-session sinks, the dangling-
// owner teardown ordering audio.cpp has to document) — the mixer UI polls at
// 1 Hz while open, so push notifications buy nothing here. It also sidesteps
// the classic stale-enumerator gotcha: GetSessionEnumerator is a snapshot,
// and a fresh manager per call always sees new sessions.
//
// Sessions are grouped by lowercase executable stem ("chrome" covers every
// chrome.exe pid), with Explorer's system-sounds session pinned under the id
// "system". A session whose process image path cannot be read (SYSTEM-owned,
// or the pid died while the session is still Inactive) is skipped outright —
// a group id is never empty, so the set-verb match stays well-defined.

#pragma once

#include <string>
#include <vector>

namespace ybar::providers {

struct AudioSessionGroup {
    std::string id;      // lowercase exe stem, or "system"
    std::string name;    // FileDescription, else basename; "System sounds"
    std::string exePath; // for the atlas's exe.<path> icon source; "" for system
    int volume = 0;      // 0-100; muted -> 0 (the master read convention)
    bool muted = false;  // every session in the group muted
    bool active = false; // any session currently AudioSessionStateActive
};

// One enumeration pass over the default render endpoint's sessions
// (Expired skipped, Inactive kept — a paused player must stay listed).
// Sorted name-alphabetically, "system" last. Empty when there is no
// default endpoint (headless session, CI runner).
std::vector<AudioSessionGroup> audioSessionGroups();

// JSON for `--query audio`.
std::string serializeAudioSessionGroups(const std::vector<AudioSessionGroup>& groups);

// `--volume <pct> <app>`: applies the master set contract to every session
// in the group (0 mutes keeping the scalar; >0 sets the scalar then unmutes,
// scalar first so a muted session cannot blip its old level). Session scalars
// are relative to the master volume — 100 means "follow master", the
// Windows 11 Settings mixer convention. True iff at least one session
// matched the id (case-insensitively) and every counted call succeeded.
bool setAudioSessionVolume(const std::string& id, int percent);

} // namespace ybar::providers
