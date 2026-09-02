// Audio provider (spec 10): WASAPI endpoint volume with push notifications.
// Publishes `volume_change` with an integer 0-100 percent, 0 when muted,
// deduped unless forced. Re-arms on default-device changes.

#pragma once

#include <functional>
#include <memory>

namespace ybar::providers {

class AudioProviderImpl;

class AudioProvider {
public:
    AudioProvider();
    ~AudioProvider();

    // Called from a WASAPI callback thread — the daemon marshals to its UI
    // thread inside this callback.
    std::function<void(int percent)> onVolume;

    bool start(); // lazily armed on the first volume_change subscription
    void stop();

    // Forced re-query (--trigger volume_change / --update): publishes even
    // when the value has not changed.
    bool refresh();

    // Sets the default render endpoint's master volume (0-100). Mirrors the
    // read path's muted->0 convention: 0 mutes (scalar kept), anything else
    // sets the scalar then unmutes. The resulting OnNotify publishes the new
    // value through the normal dedupe path, so no manual publish here.
    bool setVolume(int percent);

private:
    std::unique_ptr<AudioProviderImpl> impl_;
};

} // namespace ybar::providers
