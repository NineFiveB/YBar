import Foundation
import IOKit.ps

/// Battery / power source via public IOKit power-source APIs.
/// Emits `power_source_change` ("AC"/"BATTERY", deduped) and — beyond
/// sketchybar — `battery_change` with the native percentage, no `pmset` polling.
@MainActor
public final class PowerProvider {
    public var onEvent: ((_ name: String, _ info: String) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var lastSourceType: String?
    private var lastPercentage: Int?

    public init() {}

    public func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The callback fires on the run loop the source is scheduled on (main).
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let provider = Unmanaged<PowerProvider>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                provider.refresh(forced: false)
            }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        refresh(forced: true)
    }

    public func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    /// Read current state, emitting events for changes (or unconditionally when forced).
    public func refresh(forced: Bool) {
        let snapshot = PowerProvider.snapshot()

        if forced || snapshot.sourceType != lastSourceType {
            lastSourceType = snapshot.sourceType
            onEvent?("power_source_change", snapshot.sourceType)
        }
        if let percentage = snapshot.percentage, forced || percentage != lastPercentage {
            lastPercentage = percentage
            onEvent?("battery_change", "\(percentage)")
        }
    }

    public struct Snapshot {
        public var sourceType: String
        public var percentage: Int?
        public var isCharging: Bool
    }

    public static func snapshot() -> Snapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return Snapshot(sourceType: "AC", percentage: nil, isCharging: false)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
        let sourceType = providing == kIOPMBatteryPowerKey ? "BATTERY" : "AC"

        var percentage: Int?
        var isCharging = false
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percentage = Int((Double(current) / Double(max) * 100).rounded())
                }
                if let charging = description[kIOPSIsChargingKey] as? Bool {
                    isCharging = charging
                }
            }
        }
        return Snapshot(sourceType: sourceType, percentage: percentage, isCharging: isCharging)
    }
}
