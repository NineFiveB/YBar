// Media provider (spec 10): GlobalSystemMediaTransportControlsSessionManager.
// Publishes `media_change` with MEDIA_APP / MEDIA_STATE / MEDIA_TITLE /
// MEDIA_ARTIST / MEDIA_ALBUM. The last env is cached so `--trigger
// media_change` and a config reload replay it (the "reload mid-song keeps the
// now-playing pill" contract).
//
// Covers every SMTC-integrated player (Spotify, browsers, Groove, …), so it
// is a strict superset of the reference's two hardcoded notification names.
// MEDIA_APP carries the session's app id, not "Music"/"Spotify" — configs
// matching those literals need the documented mapping.

#pragma once

#include <functional>
#include <map>
#include <memory>
#include <string>

namespace ybar::providers {

using MediaEnvironment = std::map<std::string, std::string>;

class MediaProviderImpl;

class MediaProvider {
public:
    MediaProvider();
    ~MediaProvider();

    // Called from a WinRT event thread — the daemon marshals to its UI thread.
    std::function<void(const MediaEnvironment&)> onChange;

    bool start();
    void stop();

    // Cached last state (empty before the first session appears).
    const MediaEnvironment& current() const;

    // Forced re-query: republishes the cached state, or pulls a fresh one.
    bool refresh();

private:
    std::unique_ptr<MediaProviderImpl> impl_;
};

} // namespace ybar::providers
