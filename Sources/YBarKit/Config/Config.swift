import Foundation

/// Config discovery, sketchybar-compatible search order:
/// `-c <path>` → `$XDG_CONFIG_HOME/<name>/<name>rc` → `~/.config/<name>/<name>rc` → `~/.<name>rc`.
public enum ConfigLocator {
    public static func locate(explicitPath: String?, instanceName: String) -> URL? {
        let fileManager = FileManager.default
        if let explicitPath {
            let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append(URL(fileURLWithPath: xdg)
                .appendingPathComponent(instanceName)
                .appendingPathComponent("\(instanceName)rc"))
        }
        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".config/\(instanceName)/\(instanceName)rc"))
        candidates.append(home.appendingPathComponent(".\(instanceName)rc"))
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}

/// Watches the config directory and re-execs the config on changes
/// (whole-dir watch so plugin edits also reload), rate-limited to ~1/s.
@MainActor
public final class Hotload {
    public var enabled = false
    public var onReload: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var lastReload = Date.distantPast

    public init() {}

    public func watch(directory: URL) {
        stop()
        directoryFD = open(directory.path, O_EVTONLY)
        guard directoryFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.changed()
            }
        }
        source.setCancelHandler { [fd = directoryFD] in
            close(fd)
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        directoryFD = -1
    }

    private func changed() {
        guard enabled else { return }
        // Rate limit: the config run itself touches files in the watched dir.
        guard Date().timeIntervalSince(lastReload) > 1.0 else { return }
        lastReload = Date()
        onReload?()
    }
}
