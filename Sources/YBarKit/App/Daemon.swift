import AppKit

/// Daemon entry: builds the whole object graph and runs the app.
@MainActor
public enum Daemon {
    public static func main(arguments: [String]) -> Never {
        var configPath: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-c" || arguments[index] == "--config",
               index + 1 < arguments.count {
                configPath = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let core: DaemonCore
        do {
            core = try DaemonCore(explicitConfigPath: configPath)
        } catch {
            FileHandle.standardError.write(Data("[!] ybar failed to start: \(error)\n".utf8))
            exit(1)
        }
        DaemonCore.shared = core
        app.delegate = core
        app.run()
        exit(0)
    }
}

@MainActor
public final class DaemonCore: NSObject, NSApplicationDelegate {
    static var shared: DaemonCore?

    let instanceName: String
    let explicitConfigPath: String?

    let barManager: BarManager
    let scheduler = AnimationScheduler()
    let eventBus = EventBus()
    let scriptRunner = ScriptRunner()
    let hotload = Hotload()
    var commandHandler: CommandHandler!
    var socketServer: SocketServer!

    let workspaceProvider = WorkspaceProvider()
    let powerProvider = PowerProvider()
    let audioProvider = AudioProvider()
    let networkProvider = NetworkProvider()

    var routineTimer: Timer?
    var configURL: URL?

    init(explicitConfigPath: String?) throws {
        self.instanceName = Version.instanceName
        self.explicitConfigPath = explicitConfigPath
        self.barManager = try BarManager()
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        barManager.begin()
        wireScheduler()
        wireEventBus()
        wireProviders()
        wireMouse()
        startRoutineTimer()

        commandHandler = CommandHandler(
            barManager: barManager, eventBus: eventBus,
            scriptRunner: scriptRunner, scheduler: scheduler)
        wireCommandHandler()

        let socketPath = WireFormat.socketPath(instanceName: instanceName)
        socketServer = SocketServer(path: socketPath) { [weak self] arguments in
            self?.commandHandler.handle(arguments: arguments) ?? ""
        }
        do {
            try socketServer.start()
        } catch {
            FileHandle.standardError.write(Data("[!] \(error)\n".utf8))
            NSApp.terminate(nil)
            return
        }

        executeConfig()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
        barManager.shutdown()
    }

    // MARK: - Wiring

    private func wireScheduler() {
        scheduler.makeDisplayLink = { [weak self] target, selector in
            self?.barManager.surfaces.first?.hostView.displayLink(target: target, selector: selector)
        }
    }

    private func wireEventBus() {
        NotificationBridge.shared.bus = eventBus
        eventBus.itemsProvider = { [weak self] in
            self?.barManager.store.items ?? []
        }
        eventBus.runItemScript = { [weak self] item, environment in
            guard !item.script.isEmpty else { return }
            self?.scriptRunner.run(script: item.script, environment: environment)
        }
        eventBus.onFirstSubscription = { [weak self] eventName in
            guard let self else { return }
            switch eventName {
            case "volume_change":
                self.audioProvider.start()
            case "wifi_change":
                self.networkProvider.start()
            default:
                break
            }
        }
    }

    private func wireProviders() {
        // Workspace + power are always on (cheap; sketchybar does the same).
        workspaceProvider.onEvent = { [weak self] name, info in
            self?.eventBus.trigger(name: name, info: info)
        }
        workspaceProvider.start()

        powerProvider.onEvent = { [weak self] name, info in
            self?.eventBus.trigger(name: name, info: info)
        }
        powerProvider.start()

        audioProvider.onEvent = { [weak self] name, info in
            self?.eventBus.trigger(name: name, info: info)
        }
        networkProvider.onEvent = { [weak self] name, info in
            self?.eventBus.trigger(name: name, info: info)
        }

        barManager.onDisplaysChanged = { [weak self] in
            self?.eventBus.trigger(
                name: "display_change",
                info: "\(DisplayManager.screens().count)")
        }
    }

    private func wireMouse() {
        barManager.onItemClicked = { [weak self] item, info in
            guard let self else { return }
            let environment = [
                "NAME": item.name,
                "BUTTON": info.button,
                "MODIFIER": info.modifier,
                "INFO": "{\"button\":\"\(info.button)\",\"modifier\":\"\(info.modifier)\"}",
            ]
            if !item.clickScript.isEmpty {
                self.scriptRunner.run(script: item.clickScript, environment: environment)
            }
            self.triggerTargeted(item: item, eventName: "mouse.clicked", environment: environment)
        }
        barManager.onItemHover = { [weak self] item, entered in
            self?.triggerTargeted(
                item: item,
                eventName: entered ? "mouse.entered" : "mouse.exited",
                environment: ["NAME": item.name])
        }
        barManager.onItemScrolled = { [weak self] item, delta, modifier in
            self?.triggerTargeted(
                item: item,
                eventName: "mouse.scrolled",
                environment: [
                    "NAME": item.name,
                    "SCROLL_DELTA": "\(Int(delta))",
                    "MODIFIER": modifier,
                ])
        }
    }

    /// Mouse events route only to the involved item (sketchybar semantics),
    /// unlike bus-wide triggers.
    private func triggerTargeted(item: Item, eventName: String, environment: [String: String]) {
        guard let bit = eventBus.bit(for: eventName),
              item.updateMask & bit != 0,
              !item.script.isEmpty
        else { return }
        var env = environment
        env["SENDER"] = eventName
        env["INFO"] = env["INFO"] ?? ""
        scriptRunner.run(script: item.script, environment: env)
    }

    private func wireCommandHandler() {
        commandHandler.onReload = { [weak self] path in
            self?.reload(explicitPath: path)
        }
        commandHandler.onExit = {
            // Deferred so the IPC reply reaches the client before the process dies.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }
        commandHandler.onHotloadToggle = { [weak self] enabled in
            self?.hotload.enabled = enabled
        }
        commandHandler.forcedQueries = [
            "volume_change": { [weak self] in
                self?.audioProvider.start()
                self?.audioProvider.publishVolume(forced: true)
            },
            "power_source_change": { [weak self] in
                self?.powerProvider.publishPowerSource(forced: true)
            },
            "battery_change": { [weak self] in
                self?.powerProvider.publishBattery(forced: true)
            },
            "wifi_change": { [weak self] in
                self?.networkProvider.start()
                self?.networkProvider.refresh()
            },
            "front_app_switched": { [weak self] in
                guard let self else { return }
                self.eventBus.trigger(
                    name: "front_app_switched",
                    info: self.workspaceProvider.currentFrontApp())
            },
            "display_change": { [weak self] in
                self?.eventBus.trigger(
                    name: "display_change",
                    info: "\(DisplayManager.screens().count)")
            },
        ]
        commandHandler.onForcedUpdate = { [weak self] in
            guard let self else { return }
            self.powerProvider.refresh(forced: true)
            self.audioProvider.publishVolume(forced: true)
            self.networkProvider.refresh()
            self.eventBus.trigger(
                name: "front_app_switched",
                info: self.workspaceProvider.currentFrontApp())
        }
    }

    // MARK: - Routine timer (update_freq polling)

    private func startRoutineTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DaemonCore.shared?.routineTick()
                }
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        routineTimer = timer
    }

    private func routineTick() {
        for item in barManager.store.items {
            guard item.updateFrequency > 0, !item.script.isEmpty else { continue }
            if item.updatePolicy == .off { continue }
            if item.updatePolicy == .whenShown, !item.isVisible { continue }
            item.routineCounter += 1
            if item.routineCounter >= item.updateFrequency {
                item.routineCounter = 0
                scriptRunner.run(script: item.script, environment: [
                    "NAME": item.name, "SENDER": "routine", "INFO": "",
                ])
            }
        }
    }

    // MARK: - Config

    private func executeConfig() {
        guard let url = ConfigLocator.locate(
            explicitPath: explicitConfigPath, instanceName: instanceName) else {
            if let explicitConfigPath {
                FileHandle.standardError.write(
                    Data("[!] config not found: \(explicitConfigPath)\n".utf8))
            }
            return
        }
        configURL = url
        let directory = url.deletingLastPathComponent()
        scriptRunner.configDirectory = directory
        scriptRunner.baseEnvironment = [
            "CONFIG_DIR": directory.path,
            "BAR_NAME": instanceName,
        ]
        hotload.onReload = { [weak self] in
            self?.reload(explicitPath: nil)
        }
        hotload.watch(directory: directory, configFile: url)
        hotload.noteReloadHappened()
        scriptRunner.runConfigScript(at: url)
    }

    /// Full teardown + re-exec — no diffing (config is imperative; sketchybar's call).
    func reload(explicitPath: String?) {
        scheduler.cancelAll()
        barManager.store.removeAll()
        barManager.settings = BarSettings()
        eventBus.reset()

        if let explicitPath {
            let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                configURL = url
            }
        }
        if let configURL {
            let directory = configURL.deletingLastPathComponent()
            scriptRunner.configDirectory = directory
            scriptRunner.baseEnvironment = [
                "CONFIG_DIR": directory.path,
                "BAR_NAME": instanceName,
            ]
            hotload.watch(directory: directory, configFile: configURL)
            hotload.noteReloadHappened()
            scriptRunner.runConfigScript(at: configURL)
        }
        barManager.setNeedsRender()
    }
}
