import AppKit

/// Tracks screen topology. Any change (resolution, arrangement, add/remove,
/// menu-bar metrics) triggers a debounced full surface rebuild — sketchybar's
/// proven sledgehammer.
@MainActor
public final class DisplayManager {
    public var onChange: (() -> Void)?
    private var debounceTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    public init() {}

    public func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleChange()
            }
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        debounceTask?.cancel()
    }

    private func scheduleChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    /// Screens with their 1-based arrangement index; index 1 is the primary screen.
    public static func screens() -> [(index: Int, screen: NSScreen)] {
        NSScreen.screens.enumerated().map { (index: $0.offset + 1, screen: $0.element) }
    }
}
