import Foundation

/// Config discovery, sketchybar-compatible search order with a Lua twist:
/// `-c <path>` → per directory, `<name>rc.lua` (embedded YbarLua) is preferred
/// over the executable `<name>rc` shell script:
/// `$XDG_CONFIG_HOME/<name>/` → `~/.config/<name>/` → `~/.{<name>rc.lua,<name>rc}`.
public enum ConfigLocator {
    public static func locate(explicitPath: String?, instanceName: String) -> URL? {
        let fileManager = FileManager.default
        if let explicitPath {
            let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment

        func addDirectory(_ directory: URL) {
            candidates.append(directory.appendingPathComponent("\(instanceName)rc.lua"))
            candidates.append(directory.appendingPathComponent("\(instanceName)rc"))
        }

        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            addDirectory(URL(fileURLWithPath: xdg).appendingPathComponent(instanceName))
        }
        let home = fileManager.homeDirectoryForCurrentUser
        addDirectory(home.appendingPathComponent(".config/\(instanceName)"))
        candidates.append(home.appendingPathComponent(".\(instanceName)rc.lua"))
        candidates.append(home.appendingPathComponent(".\(instanceName)rc"))
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
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
