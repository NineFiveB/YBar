import AppKit

/// Now-playing provider: listens for the distributed notifications Music and
/// Spotify post on every playback change — public API, unlike MediaRemote,
/// which macOS 15.4+ gates to entitled processes. Emits `media_change` with
/// MEDIA_APP/MEDIA_STATE/MEDIA_TITLE/MEDIA_ARTIST/MEDIA_ALBUM.
@MainActor
public final class MediaProvider {
    public var onEvent: ((_ name: String, _ info: String, _ env: [String: String]) -> Void)?

    /// Last seen playback env, so late subscribers (config reload) can query.
    public private(set) var current: [String: String] = [:]

    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        guard tokens.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        let sources: [(notification: String, app: String)] = [
            ("com.apple.Music.playerInfo", "Music"),
            ("com.spotify.client.PlaybackStateChanged", "Spotify"),
        ]
        for source in sources {
            let token = center.addObserver(
                forName: NSNotification.Name(source.notification),
                object: nil,
                queue: .main
            ) { [weak self] note in
                let info = note.userInfo ?? [:]
                let env: [String: String] = [
                    "MEDIA_APP": source.app,
                    "MEDIA_STATE": ((info["Player State"] as? String) ?? "").lowercased(),
                    "MEDIA_TITLE": (info["Name"] as? String) ?? "",
                    "MEDIA_ARTIST": (info["Artist"] as? String) ?? "",
                    "MEDIA_ALBUM": (info["Album"] as? String) ?? "",
                ]
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.current = env
                    self.onEvent?("media_change", env["MEDIA_STATE"] ?? "", env)
                }
            }
            tokens.append(token)
        }
    }

    public func stop() {
        let center = DistributedNotificationCenter.default()
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }
}
