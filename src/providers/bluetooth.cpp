#include "providers/bluetooth.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Radios.h>
// clang-format on

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

namespace ybar::providers {

namespace {

using namespace winrt::Windows::Devices::Enumeration;
using winrt::Windows::Foundation::IInspectable;

// A scan the widget forgot to close must not hold the radio open. Refreshed by
// every startDiscovery(), so a flyout that keeps re-arming keeps scanning.
constexpr DWORD kDiscoveryTimeoutMs = 60000;
// Coalescing window. Measured on this machine: a 20 s BLE scan raised 36 Added
// and 544 Updated. Publishing per event would post 544 messages, rebuild the
// scene 544 times, and defeat the point of not blocking the message thread.
constexpr DWORD kPublishTickMs = 1000;

std::string narrow(const winrt::hstring& text) {
    if (text.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                         static_cast<int>(text.size()), nullptr, 0, nullptr,
                                         nullptr);
    std::string out(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), out.data(),
                        size, nullptr, nullptr);
    return out;
}

winrt::hstring widen(const std::string& text) {
    if (text.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                         static_cast<int>(text.size()), nullptr, 0);
    std::wstring out(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), out.data(),
                        size);
    return winrt::hstring(out);
}

// ---------------------------------------------------------------------------
// The AQS filters.
//
// NOT hand-written. Both come from the Bluetooth statics at runtime —
// BluetoothDevice/BluetoothLEDevice::GetDeviceSelectorFromPairingState(false)
// — so the strings track the OS rather than a copy in this file. Printed live
// on this machine (Windows 11 26200, SDK 26100) they are:
//
//   classic: System.Devices.DevObjectType:=5
//            AND System.Devices.Aep.ProtocolId:="{E0CBF06C-CD8B-4647-BB8A-263B43F0F974}"
//            AND (System.Devices.Aep.IsPaired:=System.StructuredQueryType.Boolean#False
//                 OR System.Devices.Aep.Bluetooth.IssueInquiry:=System.StructuredQueryType.Boolean#True)
//
//   LE:      … ProtocolId:="{BB7BB05E-5972-42B5-94FC-76EAA7084D49}" … (same shape)
//
// The IssueInquiry disjunct is the part a hand-written
// "ProtocolId AND IsPaired#False" filter misses, and it is the one that
// matters: it is what asks the stack to run an actual inquiry / advertisement
// scan instead of just replaying the AEP cache. It is also why discovery must
// be on-demand — that clause is the radio airtime.
//
// The literals below are only a fallback for a machine whose Bluetooth
// activation factories are missing (no stack at all), where the watchers
// would find nothing anyway.
constexpr wchar_t kClassicSelectorFallback[] =
    L"System.Devices.DevObjectType:=5 AND "
    L"System.Devices.Aep.ProtocolId:=\"{E0CBF06C-CD8B-4647-BB8A-263B43F0F974}\" AND "
    L"(System.Devices.Aep.IsPaired:=System.StructuredQueryType.Boolean#False OR "
    L"System.Devices.Aep.Bluetooth.IssueInquiry:=System.StructuredQueryType.Boolean#True)";
constexpr wchar_t kLeSelectorFallback[] =
    L"System.Devices.DevObjectType:=5 AND "
    L"System.Devices.Aep.ProtocolId:=\"{BB7BB05E-5972-42B5-94FC-76EAA7084D49}\" AND "
    L"(System.Devices.Aep.IsPaired:=System.StructuredQueryType.Boolean#False OR "
    L"System.Devices.Aep.Bluetooth.IssueInquiry:=System.StructuredQueryType.Boolean#True)";

// Requested properties. Every name here was verified against a live watcher on
// this machine — that verification is not optional: CreateWatcher THROWS
// 0x8002802B ("Property key syntax error") the moment one canonical name is
// wrong, so a typo takes out discovery entirely rather than yielding a null.
// Kept deliberately minimal for the same reason; Category / Manufacturer /
// ModelName / Bluetooth.Cod.* are accepted by this SDK but came back null on
// every device seen, so they buy nothing and only widen the blast radius.
std::vector<winrt::hstring> requestedProperties() {
    return {
        L"System.Devices.Aep.DeviceAddress",
        L"System.Devices.Aep.IsConnected",
        L"System.Devices.Aep.IsPaired",
        L"System.Devices.Aep.IsPresent",
        L"System.Devices.Aep.CanPair",
        L"System.Devices.Aep.SignalStrength",
        L"System.Devices.Aep.Bluetooth.Le.IsConnectable",
    };
}

// TryLookup on IMapView<hstring, IInspectable> returns a null IInspectable for
// an absent key rather than throwing, which is exactly what is needed: an
// Updated payload carries ONLY the keys that changed (observed: usually just
// SignalStrength + LastSeenTime), so every read here has to tolerate absence.
bool lookupBool(const winrt::Windows::Foundation::Collections::IMapView<winrt::hstring,
                                                                        IInspectable>& map,
                const wchar_t* key, bool& out) {
    const auto value = map.TryLookup(key);
    if (!value) return false;
    const auto property = value.try_as<winrt::Windows::Foundation::IPropertyValue>();
    if (!property ||
        property.Type() != winrt::Windows::Foundation::PropertyType::Boolean)
        return false;
    out = property.GetBoolean();
    return true;
}

bool lookupInt32(const winrt::Windows::Foundation::Collections::IMapView<winrt::hstring,
                                                                         IInspectable>& map,
                 const wchar_t* key, int& out) {
    const auto value = map.TryLookup(key);
    if (!value) return false;
    const auto property = value.try_as<winrt::Windows::Foundation::IPropertyValue>();
    if (!property || property.Type() != winrt::Windows::Foundation::PropertyType::Int32)
        return false;
    out = property.GetInt32();
    return true;
}

bool lookupString(const winrt::Windows::Foundation::Collections::IMapView<winrt::hstring,
                                                                          IInspectable>& map,
                  const wchar_t* key, std::string& out) {
    const auto value = map.TryLookup(key);
    if (!value) return false;
    const auto property = value.try_as<winrt::Windows::Foundation::IPropertyValue>();
    if (!property || property.Type() != winrt::Windows::Foundation::PropertyType::String)
        return false;
    out = narrow(property.GetString());
    return true;
}

// Honest, complete rendering of the enum — every member of
// DevicePairingResultStatus as of SDK 26100. `settings` marks the statuses a
// bar flyout genuinely cannot fix, i.e. the ones where the device wanted a
// ceremony we refuse to drive; those send the user to ms-settings:bluetooth.
struct StatusName {
    const char* text;
    bool settings;
};

StatusName pairingStatusName(DevicePairingResultStatus status) {
    switch (status) {
        case DevicePairingResultStatus::Paired: return {"paired", false};
        case DevicePairingResultStatus::NotReadyToPair: return {"not_ready", false};
        case DevicePairingResultStatus::NotPaired: return {"not_paired", false};
        case DevicePairingResultStatus::AlreadyPaired: return {"already_paired", false};
        case DevicePairingResultStatus::ConnectionRejected:
            return {"connection_rejected", false};
        case DevicePairingResultStatus::TooManyConnections:
            return {"too_many_connections", false};
        case DevicePairingResultStatus::HardwareFailure: return {"hardware_failure", false};
        case DevicePairingResultStatus::AuthenticationTimeout:
            return {"authentication_timeout", false};
        case DevicePairingResultStatus::AuthenticationNotAllowed:
            return {"authentication_not_allowed", true};
        case DevicePairingResultStatus::AuthenticationFailure:
            return {"authentication_failure", false};
        case DevicePairingResultStatus::NoSupportedProfiles:
            return {"no_supported_profiles", false};
        case DevicePairingResultStatus::ProtectionLevelCouldNotBeMet:
            return {"protection_level_not_met", true};
        case DevicePairingResultStatus::AccessDenied: return {"access_denied", true};
        case DevicePairingResultStatus::InvalidCeremonyData:
            return {"invalid_ceremony_data", true};
        case DevicePairingResultStatus::PairingCanceled: return {"pairing_canceled", false};
        case DevicePairingResultStatus::OperationAlreadyInProgress:
            return {"operation_in_progress", false};
        // Windows answers this when the device asked for a ceremony that was
        // not in the kinds we advertised — the DisplayPin / ProvidePin /
        // ConfirmPinMatch case, exactly the out-of-scope path.
        case DevicePairingResultStatus::RequiredHandlerNotRegistered:
            return {"required_handler_not_registered", true};
        case DevicePairingResultStatus::RejectedByHandler:
            return {"rejected_by_handler", true};
        case DevicePairingResultStatus::RemoteDeviceHasAssociation:
            return {"remote_device_has_association", false};
        case DevicePairingResultStatus::Failed: return {"failed", false};
        default: return {"failed", false};
    }
}

std::string ceremonyName(DevicePairingKinds kinds) {
    switch (kinds) {
        case DevicePairingKinds::ConfirmOnly: return "confirm_only";
        case DevicePairingKinds::DisplayPin: return "display_pin";
        case DevicePairingKinds::ProvidePin: return "provide_pin";
        case DevicePairingKinds::ConfirmPinMatch: return "confirm_pin_match";
        case DevicePairingKinds::ProvidePasswordCredential: return "provide_password";
        case DevicePairingKinds::ProvideAddress: return "provide_address";
        case DevicePairingKinds::None: return "";
        default: return "other";
    }
}

std::string radioStateName(winrt::Windows::Devices::Radios::RadioState state) {
    switch (state) {
        case winrt::Windows::Devices::Radios::RadioState::On: return "on";
        case winrt::Windows::Devices::Radios::RadioState::Off: return "off";
        case winrt::Windows::Devices::Radios::RadioState::Disabled: return "disabled";
        default: return "unknown";
    }
}

// What the worker is asked to do. The message thread only ever appends one of
// these; it never touches a watcher, a DeviceInformation, or a WinRT call.
enum class Command { StartDiscovery, StopDiscovery, Pair, PairCompleted };

struct Request {
    Command command = Command::StopDiscovery;
    std::string id;
};

} // namespace

// ---------------------------------------------------------------------------

// Lifetime, following MediaProviderImpl exactly: BluetoothProvider holds the
// owning shared_ptr, the worker holds a second STRONG one (nothing joins it,
// so that reference is the only guarantee the impl outlives the thread's last
// touch), and every WinRT handler holds a WEAK one it promotes on entry. A
// Stopped event or a PairAsync completion that lands after teardown therefore
// finds an expired weak_ptr or `stopping` set — never freed memory.
class BluetoothProviderImpl : public std::enable_shared_from_this<BluetoothProviderImpl> {
public:
    // --- Facade snapshot, taken at start(), cleared at stop() -------------
    std::function<void()> onNearbyChanged;
    std::function<void(const PairingOutcome&)> onPairingResult;

    // --- Cache read by the message thread --------------------------------
    mutable std::mutex cacheMutex; // guards devices/radio/callbacks
    std::map<std::string, NearbyDevice> devices;
    std::string radio = "unknown";
    // ATOMIC, not under cacheMutex: the worker loop reads it every wait to
    // choose its timeout, and a plain bool read there would be a data race
    // against the worker's own setScanning() — and against discovering(),
    // which the message thread calls.
    std::atomic<bool> scanning{false};
    // Presentation fingerprint of the last publish; a 2 Hz RSSI wobble must
    // not re-trigger the bus.
    std::string publishedFingerprint;

    // --- Worker plumbing --------------------------------------------------
    std::atomic<bool> workerLive{false};
    std::atomic<bool> stopping{false};
    std::atomic<bool> dirty{false};
    std::atomic<bool> pairInFlight{false};
    // Written by the PairingRequested callback (a WinRT threadpool thread)
    // and read by the worker. An atomic rather than a lock precisely because
    // that callback must not contend with anything.
    std::atomic<int32_t> requestedCeremony{0};
    HANDLE stopEvent = nullptr; // manual-reset
    HANDLE wakeEvent = nullptr; // auto-reset; a command was queued
    bool running = false;       // message thread only

    std::mutex queueMutex;
    std::deque<Request> queue;

    // --- Worker-thread-only WinRT state -----------------------------------
    // Nothing outside the worker ever touches these. That is the whole reason
    // the public API is a command queue: it removes the possibility of the
    // message thread calling Stop() on a watcher, or releasing the last
    // reference to one, which are both WinRT calls that can block.
    DeviceWatcher classicWatcher{nullptr};
    DeviceWatcher leWatcher{nullptr};
    ULONGLONG discoveryDeadline = 0;

    DeviceInformationCustomPairing pairCustom{nullptr};
    winrt::event_token pairToken{};
    winrt::Windows::Foundation::IAsyncOperation<DevicePairingResult> pairOperation{nullptr};
    std::string pairId;
    // Filled by the completion handler, consumed by the worker.
    std::mutex pairMutex;
    DevicePairingResultStatus pairStatus = DevicePairingResultStatus::Failed;
    bool pairResolved = false;

    // Closed here, not in stop(): stop() cannot know when the detached worker
    // stops waiting on these, and the worker's own reference is what keeps
    // this object — and therefore the handles — alive until it returns.
    ~BluetoothProviderImpl() {
        if (stopEvent) CloseHandle(stopEvent);
        if (wakeEvent) CloseHandle(wakeEvent);
    }

    void post(Command command, std::string id = {}) {
        {
            std::lock_guard<std::mutex> lock(queueMutex);
            queue.push_back(Request{command, std::move(id)});
        }
        if (wakeEvent) SetEvent(wakeEvent);
    }

    // ---- Watcher handlers. WinRT threadpool threads, possibly concurrent --
    // They do the minimum: merge into the map under cacheMutex and raise
    // `dirty`. They never publish, never call back into the daemon, and never
    // touch a watcher — the lesson from commit aea0b05, where a notification
    // callback that re-entered its own API deadlocked the message thread.

    void onAdded(const DeviceInformation& info, BluetoothKind kind) {
        NearbyDevice device;
        device.id = narrow(info.Id());
        device.name = narrow(info.Name());
        device.kind = kind;
        const auto properties = info.Properties();
        lookupString(properties, L"System.Devices.Aep.DeviceAddress", device.address);
        lookupBool(properties, L"System.Devices.Aep.CanPair", device.canPair);
        lookupBool(properties, L"System.Devices.Aep.IsPaired", device.paired);
        lookupBool(properties, L"System.Devices.Aep.IsConnected", device.connected);
        lookupBool(properties, L"System.Devices.Aep.Bluetooth.Le.IsConnectable",
                   device.connectable);
        device.hasSignal =
            lookupInt32(properties, L"System.Devices.Aep.SignalStrength", device.signal);
        if (device.id.empty()) return;
        {
            std::lock_guard<std::mutex> lock(cacheMutex);
            if (stopping) return;
            // Upsert, not insert: Added repeats for an id that was Removed and
            // came back, and the same physical device appears under both
            // protocol-qualified ids.
            devices[device.id] = std::move(device);
        }
        dirty = true;
    }

    void onUpdated(const DeviceInformationUpdate& update) {
        const std::string id = narrow(update.Id());
        if (id.empty()) return;
        const auto properties = update.Properties();
        std::lock_guard<std::mutex> lock(cacheMutex);
        if (stopping) return;
        const auto it = devices.find(id);
        if (it == devices.end()) return; // an update for something never Added
        // MERGE: an Updated payload carries only the keys that changed.
        lookupString(properties, L"System.Devices.Aep.DeviceAddress", it->second.address);
        lookupBool(properties, L"System.Devices.Aep.CanPair", it->second.canPair);
        lookupBool(properties, L"System.Devices.Aep.IsPaired", it->second.paired);
        lookupBool(properties, L"System.Devices.Aep.IsConnected", it->second.connected);
        lookupBool(properties, L"System.Devices.Aep.Bluetooth.Le.IsConnectable",
                   it->second.connectable);
        int signal = 0;
        if (lookupInt32(properties, L"System.Devices.Aep.SignalStrength", signal)) {
            it->second.hasSignal = true;
            it->second.signal = signal;
        }
        dirty = true;
    }

    void onRemoved(const DeviceInformationUpdate& update) {
        const std::string id = narrow(update.Id());
        if (id.empty()) return;
        {
            std::lock_guard<std::mutex> lock(cacheMutex);
            if (stopping) return;
            if (devices.erase(id) == 0) return;
        }
        dirty = true;
    }

    // ---- Publishing. WORKER THREAD ONLY ----------------------------------

    std::vector<NearbyDevice> snapshot() const {
        std::lock_guard<std::mutex> lock(cacheMutex);
        std::vector<NearbyDevice> out;
        out.reserve(devices.size());
        for (const auto& entry : devices) out.push_back(entry.second);
        return out;
    }

    // Everything a flyout can actually see. RSSI is quantised into the four
    // bars a UI draws, so a device whose signal jitters by 2 dBm does not
    // re-trigger the bus once a second for as long as the panel is open. The
    // raw dBm still reaches `--query`, which always reads the live cache.
    static std::string fingerprint(const std::vector<NearbyDevice>& list) {
        std::string out;
        out.reserve(list.size() * 48);
        for (const auto& device : list) {
            out += device.id;
            out += '\x1f';
            out += device.name;
            // `connectable` is deliberately NOT in the fingerprint: it flips
            // on almost every advertisement, so folding it in here made the
            // bus fire on every single tick for as long as the panel was open.
            // It still reaches --query, which always reads the live cache.
            out += static_cast<char>('0' + (device.canPair ? 1 : 0) +
                                     (device.connected ? 2 : 0));
            const int bars = !device.hasSignal ? -1
                             : device.signal >= -55 ? 3
                             : device.signal >= -70 ? 2
                             : device.signal >= -85 ? 1
                                                    : 0;
            out += static_cast<char>('a' + bars + 1);
            out += '\x1e';
        }
        return out;
    }

    void publishIfChanged() {
        const auto list = snapshot();
        const std::string mark = fingerprint(list);
        std::function<void()> callback;
        {
            std::lock_guard<std::mutex> lock(cacheMutex);
            if (mark == publishedFingerprint) return;
            publishedFingerprint = mark;
            callback = onNearbyChanged;
        }
        if (callback) callback();
    }

    void publishPairing(const PairingOutcome& outcome) {
        std::function<void(const PairingOutcome&)> callback;
        {
            std::lock_guard<std::mutex> lock(cacheMutex);
            callback = onPairingResult;
        }
        if (callback) callback(outcome);
    }

    void setScanning(bool value) { scanning = value; }

    // ---- Discovery. WORKER THREAD ONLY -----------------------------------

    DeviceWatcher makeWatcher(const winrt::hstring& selector, BluetoothKind kind) {
        // AssociationEndpoint is mandatory here. The selector also carries
        // DevObjectType:=5, but passing the kind explicitly is what the
        // Microsoft device-enumeration sample does and what was verified live.
        auto watcher = DeviceInformation::CreateWatcher(selector, requestedProperties(),
                                                        DeviceInformationKind::AssociationEndpoint);
        std::weak_ptr<BluetoothProviderImpl> weak = weak_from_this();
        watcher.Added([weak, kind](DeviceWatcher const&, DeviceInformation const& info) {
            if (auto self = weak.lock()) self->onAdded(info, kind);
        });
        watcher.Updated([weak](DeviceWatcher const&, DeviceInformationUpdate const& update) {
            if (auto self = weak.lock()) self->onUpdated(update);
        });
        watcher.Removed([weak](DeviceWatcher const&, DeviceInformationUpdate const& update) {
            if (auto self = weak.lock()) self->onRemoved(update);
        });
        // Advisory ONLY. Measured here: neither watcher raised this inside a
        // 20 s scan — the IssueInquiry query is open-ended by nature, and the
        // LE one essentially never completes. Nothing in the UI may wait on
        // it; results are published incrementally instead.
        watcher.EnumerationCompleted([weak](DeviceWatcher const&, IInspectable const&) {
            if (auto self = weak.lock()) self->dirty = true;
        });
        watcher.Stopped([weak](DeviceWatcher const&, IInspectable const&) {
            if (auto self = weak.lock()) self->dirty = true;
        });
        return watcher;
    }

    void startDiscovery() {
        discoveryDeadline = GetTickCount64() + kDiscoveryTimeoutMs;
        if (classicWatcher || leWatcher) return; // already scanning; deadline refreshed
        if (stopping) return;

        winrt::hstring classicSelector{kClassicSelectorFallback};
        winrt::hstring leSelector{kLeSelectorFallback};
        try {
            classicSelector = winrt::Windows::Devices::Bluetooth::BluetoothDevice::
                GetDeviceSelectorFromPairingState(false);
            leSelector = winrt::Windows::Devices::Bluetooth::BluetoothLEDevice::
                GetDeviceSelectorFromPairingState(false);
        } catch (const winrt::hresult_error&) {
            // No Bluetooth activation factories: keep the literals, which the
            // watchers will simply match nothing against.
        }

        // Each watcher is built FRESH. A stopped one can be restarted (checked)
        // but Stop() is asynchronous — Status goes Started -> Stopping ->
        // Stopped — and Start() while Stopping throws E_ILLEGAL_METHOD_CALL.
        // A flyout toggled quickly would hit exactly that race, so we never
        // reuse.
        try {
            classicWatcher = makeWatcher(classicSelector, BluetoothKind::Classic);
            classicWatcher.Start();
        } catch (const winrt::hresult_error& error) {
            std::fprintf(stderr, "[ybar] bluetooth classic discovery failed (0x%08x)\n",
                         static_cast<unsigned>(error.code()));
            classicWatcher = nullptr;
        }
        try {
            leWatcher = makeWatcher(leSelector, BluetoothKind::LowEnergy);
            leWatcher.Start();
        } catch (const winrt::hresult_error& error) {
            std::fprintf(stderr, "[ybar] bluetooth LE discovery failed (0x%08x)\n",
                         static_cast<unsigned>(error.code()));
            leWatcher = nullptr;
        }
        setScanning(classicWatcher || leWatcher);
        dirty = true;
    }

    void stopOne(DeviceWatcher& watcher) {
        if (!watcher) return;
        try {
            // Stop() on a watcher that is Created or already Stopped/Stopping
            // THROWS E_ILLEGAL_METHOD_CALL (verified). Guard on Status.
            const auto status = watcher.Status();
            if (status == DeviceWatcherStatus::Started ||
                status == DeviceWatcherStatus::EnumerationCompleted)
                watcher.Stop(); // returns in ~0 ms; the Stopped event follows later
        } catch (const winrt::hresult_error&) {
            // A watcher whose provider died cannot be stopped and does not
            // need to be. An exception escaping the worker would be
            // std::terminate.
        }
        watcher = nullptr;
    }

    void stopDiscovery() {
        stopOne(classicWatcher);
        stopOne(leWatcher);
        discoveryDeadline = 0;
        setScanning(false);
        // The nearby list is cleared with the scan: the rows are transient
        // radio observations, and showing a minute-old scan as if it were live
        // is worse than showing nothing.
        {
            std::lock_guard<std::mutex> lock(cacheMutex);
            devices.clear();
        }
        dirty = true;
    }

    // ---- Pairing. WORKER THREAD ONLY -------------------------------------

    void beginPair(const std::string& id) {
        PairingOutcome outcome;
        outcome.id = id;
        if (stopping) {
            pairInFlight = false; // never strand the one-at-a-time latch
            return;
        }

        DeviceInformation info{nullptr};
        try {
            // Blocking .get() is legal here and only here: this thread is the
            // provider's own MTA worker, never the STA message thread. It is a
            // local PnP cache read (measured instant, and it still resolves
            // after the watchers have stopped), and even a wedged one would
            // stall nothing but this provider — stop() never waits for it.
            info = DeviceInformation::CreateFromIdAsync(widen(id), requestedProperties(),
                                                        DeviceInformationKind::AssociationEndpoint)
                       .get();
        } catch (const winrt::hresult_error&) {
            // 0x80070002 for an id that has aged out of the AEP cache.
            outcome.status = "unavailable";
            pairInFlight = false;
            publishPairing(outcome);
            return;
        }
        if (!info) {
            outcome.status = "unavailable";
            pairInFlight = false;
            publishPairing(outcome);
            return;
        }

        try {
            const auto pairing = info.Pairing();
            pairCustom = pairing.Custom();
            if (!pairCustom) {
                outcome.status = "not_ready";
                pairInFlight = false;
                publishPairing(outcome);
                return;
            }
            pairId = id;
            requestedCeremony = 0;
            {
                std::lock_guard<std::mutex> lock(pairMutex);
                pairResolved = false;
                pairStatus = DevicePairingResultStatus::Failed;
            }

            std::weak_ptr<BluetoothProviderImpl> weak = weak_from_this();
            pairToken = pairCustom.PairingRequested(
                [weak](DeviceInformationCustomPairing const&,
                       DevicePairingRequestedEventArgs const& args) {
                    auto self = weak.lock();
                    if (!self) return;
                    const auto kind = args.PairingKind();
                    self->requestedCeremony = static_cast<int32_t>(kind);
                    // The ONLY ceremony this provider drives. Accept() is the
                    // documented in-callback response and takes none of our
                    // locks and re-enters none of our code, so it is safe to
                    // make here; anything heavier would have to hand off.
                    if (kind == DevicePairingKinds::ConfirmOnly) {
                        args.Accept();
                        return;
                    }
                    // DisplayPin / ProvidePin / ConfirmPinMatch: return
                    // WITHOUT accepting. Windows then answers the PairAsync
                    // with RejectedByHandler, which becomes needsSettings.
                });

            // Never .get() this. Completion is a user-paced ceremony that can
            // take tens of seconds or time out; blocking the worker on it
            // would make stopDiscovery() and stop() unresponsive for that
            // whole time. The operation is held in a member so its lifetime
            // does not depend on the temporary.
            //
            // DevicePairingProtectionLevel::Default, NOT
            // EncryptionAndAuthentication: raising the floor forces an
            // authenticated ceremony, which is precisely the PIN dance that is
            // out of scope. Observed discovered devices report protection
            // level None.
            pairOperation = pairCustom.PairAsync(DevicePairingKinds::ConfirmOnly,
                                                 DevicePairingProtectionLevel::Default);
            pairOperation.Completed(
                [weak](winrt::Windows::Foundation::IAsyncOperation<DevicePairingResult> const&
                           operation,
                       winrt::Windows::Foundation::AsyncStatus) {
                    auto self = weak.lock();
                    if (!self) return;
                    DevicePairingResultStatus status = DevicePairingResultStatus::Failed;
                    try {
                        const auto result = operation.GetResults();
                        if (result) status = result.Status();
                    } catch (const winrt::hresult_error&) {
                        // A cancelled or faulted operation has no result.
                    }
                    {
                        std::lock_guard<std::mutex> lock(self->pairMutex);
                        self->pairStatus = status;
                        self->pairResolved = true;
                    }
                    // Hand off. Revoking the PairingRequested registration and
                    // releasing the operation happen on the worker, never from
                    // inside a WinRT completion callback.
                    self->post(Command::PairCompleted);
                });
        } catch (const winrt::hresult_error& error) {
            std::fprintf(stderr, "[ybar] bluetooth pair failed (0x%08x)\n",
                         static_cast<unsigned>(error.code()));
            releasePairing();
            outcome.status = "failed";
            pairInFlight = false;
            publishPairing(outcome);
        }
    }

    void releasePairing() {
        try {
            if (pairCustom && pairToken) pairCustom.PairingRequested(pairToken);
        } catch (const winrt::hresult_error&) {
            // Unhooking an object whose provider died throws and has nothing
            // left to unhook.
        }
        pairToken = {};
        pairCustom = nullptr;
        pairOperation = nullptr;
    }

    void finishPair() {
        DevicePairingResultStatus status = DevicePairingResultStatus::Failed;
        {
            std::lock_guard<std::mutex> lock(pairMutex);
            if (!pairResolved) return;
            status = pairStatus;
            pairResolved = false;
        }
        PairingOutcome outcome;
        outcome.id = pairId;
        const auto named = pairingStatusName(status);
        outcome.status = named.text;
        outcome.ok = status == DevicePairingResultStatus::Paired ||
                     status == DevicePairingResultStatus::AlreadyPaired;
        outcome.ceremony =
            ceremonyName(static_cast<DevicePairingKinds>(requestedCeremony.load()));
        // Either Windows told us the ceremony was unsupported, or our handler
        // saw a non-ConfirmOnly request and declined it.
        outcome.needsSettings =
            !outcome.ok && (named.settings ||
                            (!outcome.ceremony.empty() && outcome.ceremony != "confirm_only"));
        releasePairing();
        pairId.clear();
        pairInFlight = false;
        // A newly paired device leaves the unpaired filter, so the watcher
        // will Remove it; force a republish regardless so the row disappears
        // even if the scan was already stopped.
        dirty = true;
        publishPairing(outcome);
    }

    void refreshRadio() {
        std::string state = "none";
        try {
            // Reading radio state needs no RequestAccessAsync (verified);
            // only CHANGING it does, which this provider never does.
            const auto radios = winrt::Windows::Devices::Radios::Radio::GetRadiosAsync().get();
            for (const auto& item : radios) {
                if (item.Kind() != winrt::Windows::Devices::Radios::RadioKind::Bluetooth)
                    continue;
                state = radioStateName(item.State());
                break;
            }
        } catch (const winrt::hresult_error&) {
            state = "unknown";
        }
        std::lock_guard<std::mutex> lock(cacheMutex);
        radio = state;
    }
};

// ---------------------------------------------------------------------------

BluetoothProvider::BluetoothProvider() : impl_(std::make_shared<BluetoothProviderImpl>()) {}

BluetoothProvider::~BluetoothProvider() { stop(); }

bool BluetoothProvider::start() {
    if (impl_->running) return true;
    // A worker from an earlier run can still be winding down and nothing can
    // wait for it; admitting a second would hand two threads one set of
    // watchers, events and tokens.
    if (impl_->workerLive) return false;
    impl_->stopping = false;
    if (impl_->stopEvent) CloseHandle(impl_->stopEvent);
    if (impl_->wakeEvent) CloseHandle(impl_->wakeEvent);
    impl_->stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);  // manual-reset
    impl_->wakeEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr); // auto-reset
    if (!impl_->stopEvent || !impl_->wakeEvent) {
        if (impl_->stopEvent) CloseHandle(impl_->stopEvent);
        if (impl_->wakeEvent) CloseHandle(impl_->wakeEvent);
        impl_->stopEvent = nullptr;
        impl_->wakeEvent = nullptr;
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->cacheMutex);
        impl_->onNearbyChanged = onNearbyChanged;
        impl_->onPairingResult = onPairingResult;
    }

    // STRONG reference, deliberately — the handlers it registers take weak
    // ones. With no join anywhere this is the only thing guaranteeing the impl
    // outlives the thread's last touch of it, and it is dropped below before
    // the apartment goes away.
    auto body = [impl = impl_]() mutable {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        try {
            if (!impl->stopping) impl->refreshRadio();

            HANDLE handles[2] = {impl->stopEvent, impl->wakeEvent};
            for (;;) {
                const DWORD timeout = impl->scanning || impl->dirty ? kPublishTickMs : INFINITE;
                const DWORD wait = WaitForMultipleObjects(2, handles, FALSE, timeout);
                if (wait == WAIT_OBJECT_0) break; // stopEvent
                if (impl->stopping) break;

                // Drain every queued command before doing anything else.
                for (;;) {
                    Request request;
                    {
                        std::lock_guard<std::mutex> lock(impl->queueMutex);
                        if (impl->queue.empty()) break;
                        request = std::move(impl->queue.front());
                        impl->queue.pop_front();
                    }
                    switch (request.command) {
                        case Command::StartDiscovery:
                            impl->refreshRadio();
                            impl->startDiscovery();
                            break;
                        case Command::StopDiscovery: impl->stopDiscovery(); break;
                        case Command::Pair: impl->beginPair(request.id); break;
                        case Command::PairCompleted: impl->finishPair(); break;
                    }
                    if (impl->stopping) break;
                }
                if (impl->stopping) break;

                // Auto-stop: a flyout dismissed without a stopDiscovery() must
                // not leave the radio inquiring.
                if (impl->discoveryDeadline &&
                    GetTickCount64() >= impl->discoveryDeadline)
                    impl->stopDiscovery();

                if (impl->dirty.exchange(false)) impl->publishIfChanged();
            }
        } catch (const winrt::hresult_error& error) {
            std::fprintf(stderr, "[ybar] bluetooth provider unavailable (0x%08x)\n",
                         static_cast<unsigned>(error.code()));
        }
        // stop() set `stopping` before signalling, so any handler entering a
        // guarded section from here on is already a no-op.
        try {
            impl->stopOne(impl->classicWatcher);
            impl->stopOne(impl->leWatcher);
            impl->releasePairing();
        } catch (const winrt::hresult_error&) {
            // An exception leaving a thread function is std::terminate.
        }
        // Drop every reference this thread owns BEFORE tearing the apartment
        // down: releasing the last one runs ~BluetoothProviderImpl, and that
        // must not happen inside an apartment that no longer exists.
        impl->workerLive = false;
        impl.reset();
        winrt::uninit_apartment();
    };

    impl_->workerLive = true;
    try {
        std::thread(std::move(body)).detach();
    } catch (const std::system_error&) {
        impl_->workerLive = false;
        CloseHandle(impl_->stopEvent);
        CloseHandle(impl_->wakeEvent);
        impl_->stopEvent = nullptr;
        impl_->wakeEvent = nullptr;
        return false;
    }
    impl_->running = true;
    return true;
}

void BluetoothProvider::stop() {
    if (!impl_ || !impl_->running) return;
    impl_->stopping = true;
    {
        // A late worker publish must not call back into a provider that is
        // being destroyed.
        std::lock_guard<std::mutex> lock(impl_->cacheMutex);
        impl_->onNearbyChanged = nullptr;
        impl_->onPairingResult = nullptr;
    }
    if (impl_->stopEvent) SetEvent(impl_->stopEvent);
    // Deliberately no join, for the same reason start() does not wait: the
    // worker can be inside a PnP call, and stop() runs on the message thread.
    // `stopping` and the cleared callbacks already make it inert; its own
    // reference keeps the impl and both handles alive until it returns.
    impl_->running = false;
}

bool BluetoothProvider::startDiscovery() {
    if (!impl_ || !impl_->running) return false;
    impl_->post(Command::StartDiscovery);
    return true;
}

void BluetoothProvider::stopDiscovery() {
    if (!impl_ || !impl_->running) return;
    impl_->post(Command::StopDiscovery);
}

bool BluetoothProvider::discovering() const { return impl_ && impl_->scanning; }

bool BluetoothProvider::pair(const std::string& deviceId) {
    if (!impl_ || !impl_->running || deviceId.empty()) return false;
    bool expected = false;
    // One at a time: Windows answers OperationAlreadyInProgress otherwise, and
    // the impl holds exactly one pairing registration.
    if (!impl_->pairInFlight.compare_exchange_strong(expected, true)) return false;
    impl_->post(Command::Pair, deviceId);
    return true;
}

std::vector<NearbyDevice> BluetoothProvider::nearby() const {
    if (!impl_) return {};
    return impl_->snapshot();
}

std::string BluetoothProvider::radioState() const {
    if (!impl_) return "unknown";
    std::lock_guard<std::mutex> lock(impl_->cacheMutex);
    return impl_->radio;
}

// ---------------------------------------------------------------------------

std::string serializeNearbyDevices(const std::vector<NearbyDevice>& devices) {
    std::vector<NearbyDevice> sorted = devices;
    // Named first, then strongest signal, then name — a flyout that renders
    // the first N rows gets the devices a human could actually pick.
    std::sort(sorted.begin(), sorted.end(), [](const NearbyDevice& a, const NearbyDevice& b) {
        const bool aNamed = !a.name.empty();
        const bool bNamed = !b.name.empty();
        if (aNamed != bNamed) return aNamed;
        // A device with no RSSI (every classic AEP here) sorts after the ones
        // that have one rather than pretending to be at 0 dBm.
        const int aSignal = a.hasSignal ? a.signal : -200;
        const int bSignal = b.hasSignal ? b.signal : -200;
        if (aSignal != bSignal) return aSignal > bSignal;
        if (a.name != b.name) return a.name < b.name;
        return a.id < b.id;
    });

    nlohmann::json out = nlohmann::json::array();
    for (const auto& device : sorted) {
        nlohmann::json entry{{"id", device.id},
                             {"name", device.name},
                             {"address", device.address},
                             {"kind", device.kind == BluetoothKind::LowEnergy ? "le" : "classic"},
                             {"can_pair", device.canPair},
                             {"connectable", device.connectable},
                             {"paired", device.paired},
                             {"connected", device.connected}};
        // Absent rather than a fake number when the stack gave no RSSI.
        if (device.hasSignal) entry["signal"] = device.signal;
        out.push_back(std::move(entry));
    }
    return out.dump(2);
}

std::string serializeBluetooth(const std::vector<NearbyDevice>& devices,
                               const std::string& radioState, bool scanning) {
    nlohmann::json out{{"radio", radioState}, {"scanning", scanning}};
    out["devices"] = nlohmann::json::parse(serializeNearbyDevices(devices));
    return out.dump(2);
}

} // namespace ybar::providers
