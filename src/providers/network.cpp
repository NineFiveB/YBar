#include "providers/network.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winsock2.h>
#include <ws2ipdef.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <wlanapi.h>
#include <shellapi.h>
// clang-format on

#include <memory>
#include <mutex>
#include <string>

namespace ybar::providers {

namespace {

// The SSID is 802.11 raw bytes; the reference treats it as UTF-8.
std::string ssidToString(const DOT11_SSID& ssid) {
    if (ssid.uSSIDLength == 0) return {};
    return std::string(reinterpret_cast<const char*>(ssid.ucSSID),
                       static_cast<std::size_t>(ssid.uSSIDLength));
}

} // namespace

class NetworkProviderImpl {
public:
    NetworkProvider* facade = nullptr;
    HANDLE connectivityHandle = nullptr;
    HANDLE wlanHandle = nullptr;
    std::string lastInfo;
    bool haveLast = false;
    bool running = false;
    // The connectivity and WLAN callbacks arrive on different threadpool
    // threads and can overlap.
    std::mutex publishMutex;

    // True when any WLAN interface is connected; fills `ssid` when readable.
    bool wifiConnection(std::string& ssid) {
        if (!wlanHandle) return false;
        PWLAN_INTERFACE_INFO_LIST list = nullptr;
        if (WlanEnumInterfaces(wlanHandle, nullptr, &list) != ERROR_SUCCESS || !list)
            return false;
        bool connected = false;
        for (DWORD i = 0; i < list->dwNumberOfItems; ++i) {
            const auto& info = list->InterfaceInfo[i];
            if (info.isState != wlan_interface_state_connected) continue;
            connected = true;
            DWORD size = 0;
            PWLAN_CONNECTION_ATTRIBUTES attributes = nullptr;
            // Succeeds without the Location grant on 24H2 but zeroes the SSID;
            // an empty SSID therefore means "degrade to connected", not
            // "disconnected".
            if (WlanQueryInterface(wlanHandle, &info.InterfaceGuid,
                                   wlan_intf_opcode_current_connection, nullptr, &size,
                                   reinterpret_cast<PVOID*>(&attributes),
                                   nullptr) == ERROR_SUCCESS &&
                attributes) {
                ssid = ssidToString(attributes->wlanAssociationAttributes.dot11Ssid);
                WlanFreeMemory(attributes);
            }
            break;
        }
        WlanFreeMemory(list);
        return connected;
    }

    bool online() {
        NL_NETWORK_CONNECTIVITY_HINT hint{};
        if (GetNetworkConnectivityHint(&hint) != NO_ERROR) return false;
        switch (hint.ConnectivityLevel) {
            case NetworkConnectivityLevelHintLocalAccess:
            case NetworkConnectivityLevelHintInternetAccess:
            case NetworkConnectivityLevelHintConstrainedInternetAccess:
                return true;
            default:
                return false; // Unknown / None / Hidden
        }
    }

    void publish(bool forced) {
        std::lock_guard<std::mutex> lock(publishMutex);
        std::string info;
        if (online()) {
            std::string ssid;
            const bool wifi = wifiConnection(ssid);
            info = (wifi && !ssid.empty()) ? ssid : "connected";
        }
        if (!forced && haveLast && info == lastInfo) return;
        lastInfo = info;
        haveLast = true;
        if (facade && facade->onChange) facade->onChange(info);
    }
};

namespace {

void CALLBACK connectivityChanged(void* context, NL_NETWORK_CONNECTIVITY_HINT,
                                  NL_NETWORK_CONNECTIVITY_COST_HINT) {
    if (auto* impl = static_cast<NetworkProviderImpl*>(context)) impl->publish(false);
}

void CALLBACK wlanNotification(PWLAN_NOTIFICATION_DATA data, PVOID context) {
    if (!data || data->NotificationSource != WLAN_NOTIFICATION_SOURCE_ACM) return;
    switch (data->NotificationCode) {
        case wlan_notification_acm_connection_complete:
        case wlan_notification_acm_disconnected:
            if (auto* impl = static_cast<NetworkProviderImpl*>(context)) impl->publish(false);
            break;
        default:
            break;
    }
}

} // namespace

NetworkProvider::NetworkProvider() : impl_(std::make_unique<NetworkProviderImpl>()) {
    impl_->facade = this;
}

NetworkProvider::~NetworkProvider() { stop(); }

bool NetworkProvider::start() {
    if (impl_->running) return true;

    // WLAN is optional: a desktop with no radio still reports connectivity.
    DWORD negotiated = 0;
    if (WlanOpenHandle(WLAN_API_VERSION_2_0, nullptr, &negotiated, &impl_->wlanHandle) !=
        ERROR_SUCCESS) {
        impl_->wlanHandle = nullptr;
    } else {
        WlanRegisterNotification(impl_->wlanHandle, WLAN_NOTIFICATION_SOURCE_ACM, TRUE,
                                 wlanNotification, impl_.get(), nullptr, nullptr);
    }

    if (NotifyNetworkConnectivityHintChange(connectivityChanged, impl_.get(), FALSE,
                                            &impl_->connectivityHandle) != NO_ERROR) {
        impl_->connectivityHandle = nullptr;
        if (!impl_->wlanHandle) return false; // no signal source at all
    }

    impl_->running = true;
    impl_->publish(true); // seed
    return true;
}

void NetworkProvider::stop() {
    if (!impl_ || !impl_->running) return;
    if (impl_->connectivityHandle) {
        CancelMibChangeNotify2(impl_->connectivityHandle);
        impl_->connectivityHandle = nullptr;
    }
    if (impl_->wlanHandle) {
        WlanRegisterNotification(impl_->wlanHandle, WLAN_NOTIFICATION_SOURCE_NONE, TRUE, nullptr,
                                 nullptr, nullptr, nullptr);
        WlanCloseHandle(impl_->wlanHandle, nullptr);
        impl_->wlanHandle = nullptr;
    }
    impl_->running = false;
}

bool NetworkProvider::refresh() {
    if (!impl_->running && !start()) return false;
    impl_->publish(true);
    return true;
}

void NetworkProvider::openLocationPrivacySettings() {
    ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-location", nullptr, nullptr,
                  SW_SHOWNORMAL);
}

} // namespace ybar::providers
