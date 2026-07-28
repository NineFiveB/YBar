import AppKit

/// Front app, space changes, sleep/wake — pure public NSWorkspace notifications.
/// Always armed at boot (cheap; sketchybar does the same).
@MainActor
public final class WorkspaceProvider {
    public var onEvent: ((_ name: String, _ info: String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        observe(NSWorkspace.didActivateApplicationNotification, event: "front_app_switched") { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            return app?.localizedName ?? ""
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification, event: "space_change") { _ in "" }
        observe(NSWorkspace.didWakeNotification, event: "system_woke") { _ in "" }
        observe(NSWorkspace.willSleepNotification, event: "system_will_sleep") { _ in "" }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    /// Forced re-query (`--trigger front_app_switched` / `--update`).
    public func currentFrontApp() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }

    /// The Sendable payload is extracted from the (non-Sendable) Notification
    /// before hopping to the main actor.
    private func observe(
        _ name: Notification.Name,
        event: String,
        extract: @escaping @Sendable (Notification) -> String
    ) {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] notification in
            let info = extract(notification)
            MainActor.assumeIsolated {
                self?.onEvent?(event, info)
            }
        }
        observers.append(observer)
    }
}
