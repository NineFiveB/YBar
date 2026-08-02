import AppKit
import ScreenCaptureKit

/// Capture loop for alias items: finds each alias's source window (another
/// app's menu bar item) and screenshots it via ScreenCaptureKit on the item's
/// update_freq cadence (default 2s). Requires Screen Recording permission —
/// captures fail silently (and the alias renders nothing) until granted.
@MainActor
public final class AliasProvider {
    /// All current alias items.
    public var itemsProvider: (() -> [Item])?
    /// A capture landed — repaint.
    public var onCapture: (() -> Void)?

    private var timer: Timer?
    private var inFlight = false

    public init() {}

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !inFlight, let items = itemsProvider?() else { return }
        let now = CACurrentMediaTime()
        let due = items.filter { item in
            guard let alias = item.alias, item.drawing else { return false }
            let interval = item.updateFrequency > 0 ? Double(item.updateFrequency) : 2
            return now - alias.lastCapture >= interval
        }
        guard !due.isEmpty else { return }
        inFlight = true

        Task { @MainActor [weak self] in
            defer { self?.inFlight = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false) else { return }
            var captured = false
            for item in due {
                guard let alias = item.alias else { continue }
                alias.lastCapture = CACurrentMediaTime()
                guard let window = AliasProvider.match(alias: alias, in: content.windows)
                else { continue }
                alias.windowFrame = window.frame

                let configuration = SCStreamConfiguration()
                configuration.width = Int(window.frame.width * 2)
                configuration.height = Int(window.frame.height * 2)
                configuration.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration) else { continue }
                alias.captured = image
                alias.capturedPxSize = CGSize(width: image.width, height: image.height)
                captured = true
            }
            if captured { self?.onCapture?() }
        }
    }

    /// sketchybar matching: owner app name equality (case-insensitive), then
    /// optional title substring; prefer status-item-level windows in the
    /// menu bar strip.
    private static func match(alias: AliasState, in windows: [SCWindow]) -> SCWindow? {
        let candidates = windows.filter { window in
            guard let app = window.owningApplication else { return false }
            guard app.applicationName.caseInsensitiveCompare(alias.owner) == .orderedSame
            else { return false }
            if let title = alias.windowTitle {
                guard (window.title ?? "").localizedCaseInsensitiveContains(title)
                else { return false }
            }
            return true
        }
        // Menu bar items: status level, top strip, plausibly item-sized.
        let statusItems = candidates.filter {
            $0.windowLayer == 25 && $0.frame.minY < 50 && $0.frame.width < 600
        }
        return statusItems.first
            ?? candidates.first { $0.frame.minY < 50 && $0.frame.height < 60 }
            ?? candidates.first
    }
}
