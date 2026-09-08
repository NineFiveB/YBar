// Bluetooth provider (ybar-win extension; no macOS counterpart — the
// reference shells out to blueutil). Two jobs the PowerShell probe in
// examples/sketchybar-glass/items/widgets/bluetooth.lua can never do:
//
//   DISCOVERY of nearby UNPAIRED devices, via two
//   Windows.Devices.Enumeration.DeviceWatchers (classic + LE) over the
//   AssociationEndpoint namespace, started and stopped ON DEMAND.
//
//   ConfirmOnly PAIRING, via DeviceInformationCustomPairing.PairAsync with a
//   PairingRequested handler that Accepts only the ConfirmOnly ceremony.
//
// PIN / passkey ceremonies (DisplayPin, ProvidePin, ConfirmPinMatch) are OUT
// OF SCOPE by design: a bar flyout has no text field and no place to show a
// six-digit code. Those come back as a PairingOutcome with needsSettings set,
// and the widget's footer already deep-links to ms-settings:bluetooth.
//
// THREADING CONTRACT (the whole reason this file is shaped the way it is).
// The daemon's message thread is a COM STA running a PeekMessageW pump.
// Blocking it for >5 s is AppHangB1 and Windows kills the bar. So:
//
//   * Every WinRT call in this provider happens on ITS OWN detached MTA
//     worker thread (winrt::init_apartment(multi_threaded)), exactly like
//     MediaProvider (src/providers/media.cpp).
//   * Every public method below is safe to call from the daemon's message
//     thread and NONE of them blocks on WinRT: they set an atomic, push a
//     command, and signal an event. Each one says so individually.
//   * onNearbyChanged / onPairingResult are raised FROM THE WORKER THREAD,
//     never from a WinRT threadpool callback. The daemon's implementations
//     must still do nothing but PostMessageW (spec 10, provider arming).
//   * nearby() / radioState() / discovering() read a mutex-guarded cache and
//     touch no WinRT at all, so `--query bluetooth` can run inline on the
//     message thread the way `--query audio` does.
//
// LIFETIME. The impl is a shared_ptr. The worker holds a STRONG reference and
// nothing ever joins or waits for it; every WinRT event handler holds a WEAK
// one and promotes it on entry. A DeviceWatcher's Stopped event, or a
// PairAsync completion, can therefore land after stop() or after the facade
// is destroyed and still find either an expired weak_ptr or `stopping` set.
// There is no std::thread member (that was a terminate hazard removed from
// MediaProvider); the worker is created detached inside start().

#pragma once

#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace ybar::providers {

enum class BluetoothKind {
    Classic,   // BR/EDR — System.Devices.Aep.ProtocolId {E0CBF06C-…}
    LowEnergy, // BLE    — System.Devices.Aep.ProtocolId {BB7BB05E-…}
};

// One AssociationEndpoint seen by a discovery watcher. Keyed on `id`, which is
// the DeviceInformation.Id and is protocol-qualified — a dual-mode device
// legitimately appears twice, once as "Bluetooth#Bluetooth<host>-<addr>" and
// once as "BluetoothLE#BluetoothLE<host>-<addr>" (observed on this machine).
// Dedupe by `address` is a presentation choice, deliberately left to the
// widget.
struct NearbyDevice {
    std::string id;
    // May be EMPTY. Most BLE advertisers on the air are unnamed randomised
    // beacons (30 of 34 in a 20 s scan here). Reported rather than dropped so
    // `--query bluetooth` stays a complete view; the serializer sorts named
    // devices first so a flyout that takes the top N never shows the noise.
    std::string name;
    std::string address; // System.Devices.Aep.DeviceAddress, "aa:bb:…"; may be empty
    BluetoothKind kind = BluetoothKind::Classic;
    // System.Devices.Aep.SignalStrength, RSSI in dBm. BLE ONLY in practice:
    // measured null on every classic AEP on this machine, so it is optional
    // rather than a sentinel value.
    bool hasSignal = false;
    int signal = 0;
    bool canPair = false;  // System.Devices.Aep.CanPair
    bool paired = false;   // System.Devices.Aep.IsPaired (false by construction here)
    bool connected = false; // System.Devices.Aep.IsConnected
    // System.Devices.Aep.Bluetooth.Le.IsConnectable — the honest "you could
    // actually pair this" signal for LE. CanPair came back true for every one
    // of the 30-odd anonymous beacons on the air here, so it does not
    // discriminate; IsConnectable does. Always false for classic.
    bool connectable = false;
};

// The result of one pair() attempt, reported once.
struct PairingOutcome {
    std::string id;
    // Lowercase snake_case rendering of DevicePairingResultStatus, reported
    // honestly and completely: "paired", "already_paired", "not_ready",
    // "authentication_timeout", "rejected_by_handler", … See the table in
    // bluetooth.cpp. "unavailable" when the device id could not be resolved
    // at all (a stale row: CreateFromIdAsync throws 0x80070002 for an AEP
    // that has aged out).
    std::string status;
    bool ok = false; // Paired or AlreadyPaired
    // The device wanted a ceremony we refuse to drive (DisplayPin,
    // ProvidePin, ConfirmPinMatch, …) or Windows rejected our ConfirmOnly-only
    // handler. The widget should fall back to ms-settings:bluetooth.
    bool needsSettings = false;
    // The DevicePairingKinds the device actually asked for, when its
    // PairingRequested reached us; "" when it never did.
    std::string ceremony;
};

class BluetoothProviderImpl;

class BluetoothProvider {
public:
    BluetoothProvider();
    ~BluetoothProvider(); // calls stop(); does not join the worker

    // Raised on the PROVIDER'S WORKER THREAD (never a WinRT threadpool
    // thread, and never more than once per publish tick — a 20 s BLE scan
    // here produced 544 Updated events, so the worker coalesces). The
    // daemon's handler must do nothing but PostMessageW.
    std::function<void()> onNearbyChanged;
    std::function<void(const PairingOutcome&)> onPairingResult;

    // MESSAGE THREAD. Spawns the detached MTA worker and returns immediately;
    // "true" means armed, not "Bluetooth works". Discovery is NOT started
    // here. Set the callbacks BEFORE calling: the impl snapshots them, so a
    // late worker publish can never call through a destroyed facade.
    bool start();

    // MESSAGE THREAD. Signals the worker to tear down and returns at once.
    // Never joins — the worker can be parked in a PnP call, and a join here
    // is the AppHangB1 that MediaProvider::stop() was rewritten to avoid.
    void stop();

    // MESSAGE THREAD. Ask the worker to build and Start() the two watchers.
    // Costs radio airtime and battery (the classic selector asks the stack to
    // IssueInquiry), so this is explicitly on-demand: the flyout calls it when
    // the Nearby section opens. Re-calling while a scan runs just refreshes
    // the auto-stop deadline. Returns false only if the provider is not armed.
    bool startDiscovery();

    // MESSAGE THREAD. Stops both watchers. Safe to call when nothing is
    // scanning. A scan also auto-stops after kDiscoveryTimeoutMs so a flyout
    // that is dismissed without a matching call cannot leave the radio
    // scanning forever.
    void stopDiscovery();

    // MESSAGE THREAD. Cached flag; no WinRT, no blocking.
    bool discovering() const;

    // MESSAGE THREAD. Queues a ConfirmOnly pairing attempt for one discovered
    // id and returns immediately — the answer arrives later on
    // onPairingResult. Returns false if the provider is not armed or another
    // pairing is already in flight (Windows would answer
    // OperationAlreadyInProgress anyway).
    bool pair(const std::string& deviceId);

    // MESSAGE THREAD. Snapshot BY VALUE of the discovery cache: the caller's
    // read must not race the WinRT threads that mutate it.
    std::vector<NearbyDevice> nearby() const;

    // MESSAGE THREAD. Cached Windows.Devices.Radios state for the Bluetooth
    // radio, refreshed by the worker at start() and at each startDiscovery():
    // "on" / "off" / "disabled" / "unknown", or "none" when the machine has no
    // Bluetooth radio. This replaces the widget's PowerShell reflection dance
    // (bluetooth.lua's IAsyncOperation`1 AsTask bridge) — reading it here is a
    // mutex-guarded string copy, not a 5 s process spawn.
    std::string radioState() const;

private:
    std::shared_ptr<BluetoothProviderImpl> impl_;
};

// JSON for `--query bluetooth`, in the style of
// serializeAudioSessionGroups(): a pure function of a snapshot, safe inline on
// the message thread. Sorted named-first, then strongest signal first, then by
// name — so a flyout that takes the first N rows gets the useful ones.
std::string serializeNearbyDevices(const std::vector<NearbyDevice>& devices);

// The same list wrapped with the two bits of context a flyout needs to render
// the section header: {"radio":"on","scanning":true,"devices":[…]}.
std::string serializeBluetooth(const std::vector<NearbyDevice>& devices,
                               const std::string& radioState, bool scanning);

} // namespace ybar::providers
