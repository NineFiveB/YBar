import Darwin
import Foundation
import IOKit

/// Built-in CPU/memory sampler — kills the #1 sketchybar external-helper use
/// case. Lazily armed on the first `system_stats` subscription; publishes every
/// `interval` seconds with generous timer leeway so wakeups coalesce.
///
/// Event contract: `system_stats` with INFO = {"cpu": <0-100>, "memory": <0-100>}
/// and env vars CPU_USAGE / MEMORY_USAGE (integer percent) and CPU_FRACTION /
/// MEMORY_FRACTION (0...1, two decimals — ready for `ybar --push`). GPU_USAGE /
/// GPU_FRACTION / GPU_MEMORY_USED_MB are env-only (INFO is the cross-port
/// contract) and absent when the accelerator driver publishes no figure.
@MainActor
public final class SystemStatsProvider {
    public struct GPUSample: Equatable {
        public var utilization: Double
        public var memoryUsedBytes: UInt64?
    }

    public var onSample: ((_ cpuFraction: Double, _ memoryFraction: Double, _ gpu: GPUSample?) -> Void)?

    private var timer: DispatchSourceTimer?
    private var previousTicks: (busy: UInt64, total: UInt64)?
    /// Matched once and kept: an IOServiceGetMatchingServices per tick would
    /// be the most expensive thing in the sampler.
    private var accelerators: [io_registry_entry_t] = []
    private var acceleratorsMatched = false

    public init() {}

    deinit {
        accelerators.forEach { IOObjectRelease($0) }
    }

    public func start(interval: TimeInterval = 2.0) {
        guard timer == nil else { return }
        // Prime the tick baseline so the first published delta is meaningful.
        _ = cpuFraction()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        previousTicks = nil
    }

    public var isRunning: Bool { timer != nil }

    public func sample() {
        let cpu = cpuFraction() ?? 0
        let memory = SystemStatsProvider.memoryFraction()
        onSample?(cpu, memory, gpuSample())
    }

    // MARK: - GPU (accelerator driver PerformanceStatistics)

    /// Plain IOKit, no entitlement — but the keys are per-vendor driver
    /// properties, not API. A Mac with several accelerators (integrated plus
    /// discrete or eGPU) reports the busiest one.
    private func gpuSample() -> GPUSample? {
        if !acceleratorsMatched {
            acceleratorsMatched = true
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
            else { return nil }
            defer { IOObjectRelease(iterator) }
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                accelerators.append(entry)
                entry = IOIteratorNext(iterator)
            }
        }
        var busiest: GPUSample?
        for entry in accelerators {
            guard let statistics = IORegistryEntryCreateCFProperty(
                    entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let sample = SystemStatsProvider.gpuSample(performance: statistics)
            else { continue }
            if let current = busiest, current.utilization >= sample.utilization { continue }
            busiest = sample
        }
        return busiest
    }

    /// Pure reduction over one accelerator's PerformanceStatistics. Apple
    /// silicon (AGX) and AMD publish "Device Utilization %", Intel
    /// "GPU Activity(%)"; memory is "In use system memory" in bytes where
    /// present. Split out for testability; nil when no utilization figure
    /// exists, so callers omit the keys rather than publish zeros.
    nonisolated static func gpuSample(performance: [String: Any]) -> GPUSample? {
        func number(_ key: String) -> Double? {
            (performance[key] as? NSNumber)?.doubleValue
        }
        guard let percent = number("Device Utilization %") ?? number("GPU Activity(%)") else {
            return nil
        }
        let memory = number("In use system memory").map { UInt64(max(0, $0)) }
        return GPUSample(utilization: min(1, max(0, percent / 100)), memoryUsedBytes: memory)
    }

    // MARK: - CPU (aggregate host ticks, delta between samples)

    private func cpuFraction() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let current = (busy: busy, total: busy + idle)

        defer { previousTicks = current }
        return SystemStatsProvider.cpuFraction(previous: previousTicks, current: current)
    }

    /// Pure: the busy share of the ticks elapsed since the previous sample;
    /// nil without a baseline or when the clock did not advance. Split out
    /// for testability.
    nonisolated static func cpuFraction(
        previous: (busy: UInt64, total: UInt64)?, current: (busy: UInt64, total: UInt64)
    ) -> Double? {
        guard let previous, current.total > previous.total else { return nil }
        let deltaTotal = Double(current.total - previous.total)
        let deltaBusy = Double(current.busy - previous.busy)
        return min(1, max(0, deltaBusy / deltaTotal))
    }

    // MARK: - Memory (active + wired + compressed over physical)

    static func memoryFraction() -> Double {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let used = (Double(info.active_count) + Double(info.wire_count)
                    + Double(info.compressor_page_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return min(1, max(0, used / total))
    }
}
