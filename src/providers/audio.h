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

private:
    std::unique_ptr<AudioProviderImpl> impl_;
};

} // namespace ybar::providers
