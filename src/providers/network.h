// Network provider (spec 10): connectivity + SSID.
//
// Publishes `wifi_change` with the reference's exact INFO contract:
//   ""           offline
//   "connected"  online, but not Wi-Fi or the SSID is unavailable
//   "<ssid>"     online over Wi-Fi with the SSID readable
//
// Windows 11 24H2 gates SSID reads behind the Location privacy setting the
// same way macOS 14 gates CoreWLAN behind Core Location — without the grant
// this degrades to "connected", exactly like the reference. `--bar
// wifi_ssid_prompt=on` opens ms-settings:privacy-location.

#pragma once

#include <functional>
#include <memory>
#include <string>

namespace ybar::providers {

class NetworkProviderImpl;

class NetworkProvider {
public:
    NetworkProvider();
    ~NetworkProvider();

    // Called from an OS notification thread — the daemon marshals to its UI
    // thread inside this callback.
    std::function<void(const std::string& info)> onChange;

    bool start(); // lazily armed on the first wifi_change subscription
    void stop();

    bool refresh(); // forced re-query, publishes even when unchanged

    // `wifi_ssid_prompt=on`: Windows has no in-process authorization dialog
    // for this, so the equivalent is deep-linking the privacy page.
    static void openLocationPrivacySettings();

private:
    std::unique_ptr<NetworkProviderImpl> impl_;
};

} // namespace ybar::providers
