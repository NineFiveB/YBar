import Darwin
import Foundation

/// Built-in CPU/memory sampler — kills the #1 sketchybar external-helper use
/// case. Lazily armed on the first `system_stats` subscription; publishes every
/// `interval` seconds with generous timer leeway so wakeups coalesce.
///
/// Event contract: `system_stats` with INFO = {"cpu": <0-100>, "memory": <0-100>}
/// and env vars CPU_USAGE / MEMORY_USAGE (integer percent) and CPU_FRACTION /
/// MEMORY_FRACTION (0...1, two decimals — ready for `ybar --push`).
@MainActor
public final class SystemStatsProvider {
    public var onSample: ((_ cpuFraction: Double, _ memoryFraction: Double) -> Void)?

    private var timer: DispatchSourceTimer?
    private var previousTicks: (busy: UInt64, total: UInt64)?

    public init() {}

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
        onSample?(cpu, memory)
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
        let total = busy + idle

        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return nil }
        let deltaTotal = Double(total - previous.total)
        let deltaBusy = Double(busy - previous.busy)
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
