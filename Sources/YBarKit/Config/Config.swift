import Foundation

/// Config discovery, sketchybar-compatible search order with a Lua twist:
/// `-c <path>` → the selected theme (default instance only) → per directory,
/// `<name>rc.lua` (embedded YbarLua) is preferred over the executable
/// `<name>rc` shell script, then the declarative `<name>rc.jsonc` / `<name>.jsonc`:
/// `$XDG_CONFIG_HOME/<name>/` → `~/.config/<name>/` → `~/.{<name>rc.lua,<name>rc}`.
public enum ConfigLocator {
    /// What discovery settled on, and why — the daemon needs the "why" to warn
    /// about the one silent case (see `shadowed`).
    public struct Resolution: Equatable {
        /// The config that will be loaded.
        public let url: URL
        /// The recorded theme this came from, when it came from one.
        public let theme: String?
        /// The config ordinary discovery would have loaded had no theme been
        /// recorded. Only ever set alongside `theme`, and only when such a file
        /// exists: `ybar-theme use` (pre-1.0) wrote `current-theme`
        /// unconditionally while nothing read it, so an upgraded install can
        /// carry a selection the user has long since replaced with a config of
        /// their own. The theme still wins — that precedence is documented and
        /// is what makes a theme survive a restart — but the daemon says so
        /// instead of letting the user's file disappear without a word.
        public let shadowed: URL?
    }

    public static func locate(
        explicitPath: String?, instanceName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        executable: URL? = AppBundle.executableURL()
    ) -> URL? {
        resolve(explicitPath: explicitPath, instanceName: instanceName,
                environment: environment, home: home, executable: executable)?.url
    }

    public static func resolve(
        explicitPath: String?, instanceName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        executable: URL? = AppBundle.executableURL()
    ) -> Resolution? {
        let fileManager = FileManager.default
        if let explicitPath {
            let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return Resolution(url: url, theme: nil, shadowed: nil)
        }
        // `ybar theme use` records a choice in ~/.config/ybar/current-theme;
        // honouring it here is what makes a theme survive restarts and
        // autostart — otherwise "recorded; start ybar to apply" would be a
        // lie. Explicit -c above always wins; `ybar theme reset` clears it.
        // Gated to the default instance, as the port is (config.cpp): the
        // state file is not instance-scoped, and a renamed secondary bar
        // must not be hijacked by the primary's theme.
        var theme: (name: String, entry: URL)?
        if instanceName == "ybar", let name = ThemeCatalog.currentName(home: home),
           let entry = ThemeCatalog.currentEntry(
               home: home,
               roots: ThemeCatalog.roots(home: home, executable: executable, environment: environment)) {
            theme = (name, entry)
        }
        var candidates: [URL] = []

        func addDirectory(_ directory: URL) {
            candidates.append(directory.appendingPathComponent("\(instanceName)rc.lua"))
            candidates.append(directory.appendingPathComponent("\(instanceName)rc"))
            // JSONC configs are first-class (THEMES.md, ybar-theme) and the
            // daemon dispatches them by extension; the Windows port lists the
            // same two names in the same order.
            candidates.append(directory.appendingPathComponent("\(instanceName)rc.jsonc"))
            candidates.append(directory.appendingPathComponent("\(instanceName).jsonc"))
        }

        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            addDirectory(URL(fileURLWithPath: xdg).appendingPathComponent(instanceName))
        }
        addDirectory(home.appendingPathComponent(".config/\(instanceName)"))
        candidates.append(home.appendingPathComponent(".\(instanceName)rc.lua"))
        candidates.append(home.appendingPathComponent(".\(instanceName)rc"))
        let discovered = candidates.first { fileManager.fileExists(atPath: $0.path) }
        if let theme {
            return Resolution(url: theme.entry, theme: theme.name, shadowed: discovered)
        }
        guard let discovered else { return nil }
        return Resolution(url: discovered, theme: nil, shadowed: nil)
    }
}

/// Watches the config for changes and re-execs it, with three deliberate behaviors:
/// - the config FILE's own vnode is watched (a directory kqueue source never fires
///   for in-place writes — nano/VS Code saves were invisible), re-armed after
///   rename-style saves replace the vnode; the directory is watched too so plugin
///   edits and atomic saves reload as well
/// - bursts coalesce through a trailing-edge debounce (no save is dropped)
/// - events within 1 s after a reload are suppressed: the config run's own writes
///   into the watched directory must not re-trigger a reload loop (the sketchybar
///   tradeoff; a genuine save inside that window is the rare loss)
@MainActor
public final class Hotload {
    public var enabled = false
    public var onReload: (() -> Void)?

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedFile: URL?
    private var pendingReload: DispatchWorkItem?
    private var lastReload = Date.distantPast

    public init() {}

    public func watch(directory: URL, configFile: URL) {
        stop()
        watchedFile = configFile
        directorySource = Hotload.makeSource(path: directory.path) { [weak self] in
            self?.changed()
        }
        armFileSource()
    }

    public func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        pendingReload?.cancel()
        pendingReload = nil
    }

    /// A reload happened by other means (`--reload`, initial config run) — its own
    /// file writes must not re-trigger.
    public func noteReloadHappened() {
        lastReload = Date()
        pendingReload?.cancel()
        pendingReload = nil
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        guard let file = watchedFile else { return }
        fileSource = Hotload.makeSource(path: file.path) { [weak self] in
            self?.changed()
            // Rename-style saves (vim, TextEdit) replace the vnode; re-arm on the
            // new file once the editor has finished writing it.
            let work = DispatchWorkItem {
                MainActor.assumeIsolated { self?.armFileSource() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private static func makeSource(
        path: String, handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        guard enabled else { return }
        guard Date().timeIntervalSince(lastReload) > 1.0 else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                self.lastReload = Date()
                self.onReload?()
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
