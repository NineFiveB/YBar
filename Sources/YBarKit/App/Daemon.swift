import AppKit
import CoreText

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
    let mediaProvider = MediaProvider()
    let aliasProvider = AliasProvider()
    let powerProvider = PowerProvider()
    let audioProvider = AudioProvider()
    let networkProvider = NetworkProvider()
    let statsProvider = SystemStatsProvider()

    var routineTimer: Timer?
    var configURL: URL?
    /// Last reported modifier state (modifier_change dedupe).
    var lastModifier = "none"
    var luaRuntime: LuaRuntime?

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
        commandHandler.onAliasAdded = { [weak self] _ in
            self?.aliasProvider.start()
        }
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
        // The link is bound to a surface's view; a rebuild (monitor plug/unplug,
        // display-policy change) would otherwise strand a running animation clock.
        barManager.onSurfacesRebuilt = { [weak self] in
            self?.scheduler.reattachDisplayLink()
        }
        // Late-activating fonts (per-user Nerd Fonts registering after login)
        // resolve to a fallback that would otherwise be cached forever.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let core = DaemonCore.shared else { return }
                core.barManager.fontCache.clear()
                core.barManager.setNeedsRender()
            }
        }
    }

    private func wireEventBus() {
        NotificationBridge.shared.bus = eventBus
        eventBus.itemsProvider = { [weak self] in
            self?.barManager.store.items ?? []
        }
        eventBus.runItemScript = { [weak self] item, environment in
            self?.dispatchItemScript(item: item, environment: environment)
        }
        eventBus.onFirstSubscription = { [weak self] eventName in
            guard let self else { return }
            switch eventName {
            case "volume_change":
                self.audioProvider.start()
            case "wifi_change":
                self.networkProvider.start()
            case "system_stats":
                self.statsProvider.start()
            default:
                break
            }
        }
    }

    private func wireProviders() {
        // Workspace + power are always on (cheap; sketchybar does the same).
        workspaceProvider.onEvent = { [weak self] name, info in
            self?.eventBus.trigger(name: name, info: info)
            if name == "front_app_switched" {
                // display=active items follow keyboard focus across screens.
                self?.barManager.setNeedsRender()
            }
            if name == "space_change" || name == "front_app_switched" {
                // fullscreen_show: the active Space (or a fullscreen toggle
                // that keeps focus) may have changed fullscreen-ness.
                self?.barManager.updateFullscreenElevation()
            }
        }
        workspaceProvider.start()

        powerProvider.onEvent = { [weak self] name, info in
            self?.eventBus.trigger(name: name, info: info)
        }
        powerProvider.start()

        mediaProvider.onEvent = { [weak self] name, info, env in
            self?.eventBus.trigger(name: name, info: info, extraEnvironment: env)
        }
        mediaProvider.start()

        audioProvider.onEvent = { [weak self] name, info in
            self?.eventBus.trigger(name: name, info: info)
        }
        networkProvider.onEvent = { [weak self] name, info in
            self?.eventBus.trigger(name: name, info: info)
        }
        DaemonHooks.shared.requestLocation = { [weak self] in
            self?.networkProvider.requestLocationAuthorization()
        }

        statsProvider.onSample = { [weak self] cpu, memory in
            self?.eventBus.trigger(
                name: "system_stats",
                info: "{\"cpu\": \(Int((cpu * 100).rounded())), \"memory\": \(Int((memory * 100).rounded()))}",
                extraEnvironment: [
                    "CPU_USAGE": "\(Int((cpu * 100).rounded()))",
                    "CPU_FRACTION": String(format: "%.2f", cpu),
                    "MEMORY_USAGE": "\(Int((memory * 100).rounded()))",
                    "MEMORY_FRACTION": String(format: "%.2f", memory),
                    "DISK_FREE_GB": DaemonCore.diskGB().free,
                    "DISK_TOTAL_GB": DaemonCore.diskGB().total,
                    "THERMAL_STATE": DaemonCore.thermalStateName(),
                ])
        }

        barManager.onDisplaysChanged = { [weak self] in
            self?.eventBus.trigger(
                name: "display_change",
                info: "\(DisplayManager.screens().count)")
        }
        aliasProvider.itemsProvider = { [weak self] in
            self?.barManager.store.items.filter { $0.alias != nil } ?? []
        }
        aliasProvider.onCapture = { [weak self] in
            self?.barManager.setNeedsRender()
        }
        barManager.onMarqueeDemand = { [weak self] active in
            guard let self else { return }
            self.scheduler.continuousDemand = active
            if active, self.scheduler.onFrame == nil {
                self.scheduler.onFrame = { [weak self] in self?.barManager.setNeedsRender() }
            }
        }
        barManager.onGlobalMouseEnter = { [weak self] in
            self?.eventBus.trigger(name: "mouse.entered.global")
        }
        barManager.onGlobalMouseExit = { [weak self] in
            self?.eventBus.trigger(name: "mouse.exited.global")
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
            // Alias click forwarding: no script and no Lua handler means the
            // click belongs to the captured source item.
            if item.kind == .alias, item.clickScript.isEmpty, !item.hasLuaHandlers,
               let frame = item.alias?.windowFrame, frame != .zero {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                for eventType in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: eventType,
                            mouseCursorPosition: center, mouseButton: .left)?
                        .post(tap: .cghidEventTap)
                }
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
        // Modifier-key changes as an event (live ⌥-to-reveal UX). Both
        // monitors are needed: the local one sees events while the pointer
        // is over our windows, the global one covers everywhere else.
        let reportFlags: (NSEvent.ModifierFlags) -> Void = { [weak self] flags in
            let name = MetalHostView.modifierName(flags)
            guard let self, name != self.lastModifier else { return }
            self.lastModifier = name
            self.eventBus.trigger(name: "modifier_change",
                                  extraEnvironment: ["MODIFIER": name])
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { reportFlags(event.modifierFlags) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { reportFlags(event.modifierFlags) }
            return event
        }
        barManager.onSliderDragStarted = { [weak self] item in
            // An in-flight percentage animation would fight the drag every frame.
            self?.scheduler.cancel(key: "item.\(item.id).slider.percentage")
        }
        barManager.onSliderChanged = { [weak self] item, percentage in
            guard let self else { return }
            let environment = [
                "NAME": item.name,
                "PERCENTAGE": "\(Int(percentage.rounded()))",
                "BUTTON": "left",
                "MODIFIER": "none",
            ]
            if !item.clickScript.isEmpty {
                self.scriptRunner.run(script: item.clickScript, environment: environment)
            }
            self.triggerTargeted(item: item, eventName: "mouse.clicked", environment: environment)
        }
    }

    /// Free/total capacity of the user data volume, in whole GB strings.
    static func diskGB() -> (free: String, total: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        let free = (values?.volumeAvailableCapacityForImportantUsage).map {
            "\(Int($0 / 1_000_000_000))" } ?? ""
        let total = (values?.volumeTotalCapacity).map {
            "\(Int(Double($0) / 1_000_000_000))" } ?? ""
        return (free, total)
    }

    static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Mouse events route only to the involved item (sketchybar semantics),
    /// unlike bus-wide triggers.
    private func triggerTargeted(item: Item, eventName: String, environment: [String: String]) {
        guard let bit = eventBus.bit(for: eventName),
              item.updateMask & bit != 0,
              !item.script.isEmpty || item.hasLuaHandlers
        else { return }
        var env = environment
        env["SENDER"] = eventName
        env["INFO"] = env["INFO"] ?? ""
        dispatchItemScript(item: item, environment: env)
    }

    /// Lua-first dispatch: an embedded callback handles the event in-process;
    /// otherwise the shell script contract runs.
    func dispatchItemScript(item: Item, environment: [String: String]) {
        if let luaRuntime, luaRuntime.handleEvent(item: item, environment: environment) {
            return
        }
        guard !item.script.isEmpty else { return }
        scriptRunner.run(script: item.script, environment: environment)
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
            "system_stats": { [weak self] in
                self?.statsProvider.start()
                self?.statsProvider.sample()
            },
            "media_change": { [weak self] in
                // Replay the last seen playback state — the provider is
                // notification-driven, so a bare trigger (or a config reload
                // mid-song) would otherwise dispatch with no MEDIA_* env and
                // widgets would read it as "stopped".
                guard let self, !self.mediaProvider.current.isEmpty else { return }
                let env = self.mediaProvider.current
                self.eventBus.trigger(
                    name: "media_change",
                    info: env["MEDIA_STATE"] ?? "",
                    extraEnvironment: env)
            },
        ]
        commandHandler.dispatchItem = { [weak self] item, environment in
            self?.dispatchItemScript(item: item, environment: environment)
        }
        commandHandler.onForcedUpdate = { [weak self] in
            guard let self else { return }
            self.powerProvider.refresh(forced: true)
            self.audioProvider.publishVolume(forced: true)
            self.networkProvider.refresh()
            if self.statsProvider.isRunning { self.statsProvider.sample() }
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
            guard item.updateFrequency > 0,
                  !item.script.isEmpty || item.hasLuaHandlers else { continue }
            if item.updatePolicy == .off { continue }
            if item.updatePolicy == .whenShown, !item.drawing { continue }
            item.routineCounter += 1
            if item.routineCounter >= item.updateFrequency {
                item.routineCounter = 0
                dispatchItemScript(item: item, environment: [
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
        runConfig(at: url)
    }

    /// `.lua` configs run in the embedded YbarLua runtime, `.json`/`.jsonc`
    /// configs load declaratively; anything else is an executable script
    /// driving the CLI (sketchybar model).
    private func runConfig(at url: URL) {
        if url.pathExtension == "json" || url.pathExtension == "jsonc" {
            JSONCConfig.run(at: url) { [weak self] arguments in
                self?.commandHandler.handle(arguments: arguments) ?? ""
            }
        } else if url.pathExtension == "lua" {
            if luaRuntime == nil {
                let runtime = LuaRuntime(
                    barManager: barManager, eventBus: eventBus, scheduler: scheduler)
                runtime.forcedTrigger = { [weak self] name in
                    guard let forced = self?.commandHandler.forcedQueries[name] else { return false }
                    forced()
                    return true
                }
                luaRuntime = runtime
            }
            if let error = luaRuntime?.runConfig(at: url) {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
            }
        } else {
            scriptRunner.runConfigScript(at: url)
        }
    }

    /// Full teardown + re-exec — no diffing (config is imperative; sketchybar's call).
    func reload(explicitPath: String?) {
        scheduler.cancelAll()
        barManager.store.removeAll()
        barManager.settings = BarSettings()
        barManager.fontCache.clear()
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
            runConfig(at: configURL)
        }
        // Settings were reset above; without re-evaluating, a bar elevated
        // over a fullscreen Space stays stuck at status level (or, with the
        // new config's fullscreen_show, stays buried) until the next
        // workspace event.
        barManager.updateFullscreenElevation()
        // A reload mid-song would otherwise leave the now-playing pill
        // hidden until the next track change.
        commandHandler.forcedQueries["media_change"]?()
        barManager.setNeedsRender()
    }
}
