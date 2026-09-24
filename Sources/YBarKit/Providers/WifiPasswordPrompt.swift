import AppKit

/// Key window for a Wi-Fi password. The bar panel cannot become key, so this
/// is a separate activating panel. The password stays in this type and in
/// `networksetup`'s stdin; it is never logged or handed to Lua.
@MainActor
final class WifiPasswordPrompt: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = WifiPasswordPrompt()

    private var panel: WifiPasswordWindow?
    private var field: NSSecureTextField?
    private var message: NSTextField?
    private var joinButton: NSButton?
    private var ssid = ""
    private var onFinish: ((Bool) -> Void)?
    private var joining = false
    /// App that was frontmost before the panel took focus, restored on close.
    private var previousApp: NSRunningApplication?
    /// Bumped when a new prompt replaces one whose join is still in flight.
    private var requestID = 0

    func present(ssid: String, onFinish: @escaping (Bool) -> Void) {
        let name = WifiScan.sanitize(ssid)
        guard !name.isEmpty else {
            onFinish(false)
            return
        }
        let previous = self.onFinish
        self.onFinish = nil
        previous?(false)

        requestID += 1
        joining = false
        self.ssid = name
        self.onFinish = onFinish
        if previousApp == nil {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = front
            }
        }
        let window = ensurePanel()
        window.title = name
        field?.stringValue = ""
        setBusy(false)
        setMessage(nil, failure: false)
        place(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    private func ensurePanel() -> WifiPasswordWindow {
        if let panel { return panel }
        let window = WifiPasswordWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 168),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.delegate = self
        window.title = "Wi-Fi"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = true

        let field = NSSecureTextField(string: "")
        field.placeholderString = "Password"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.setAccessibilityLabel("Password")
        field.translatesAutoresizingMaskIntoConstraints = false

        let message = NSTextField(wrappingLabelWithString: "")
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2
        message.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        cancel.translatesAutoresizingMaskIntoConstraints = false
        let join = NSButton(title: "Join", target: self, action: #selector(joinPressed))
        join.keyEquivalent = "\r"
        join.bezelStyle = .rounded
        join.translatesAutoresizingMaskIntoConstraints = false

        let backdrop = makeBackdrop()
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(backdrop)
        content.addSubview(field)
        content.addSubview(message)
        content.addSubview(cancel)
        content.addSubview(join)
        // The field and Join used to trail the window edge: a fixed width in a
        // trailing stack ignored the right inset. These constants are the gap.
        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),

            message.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            message.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            message.heightAnchor.constraint(equalToConstant: 28),

            join.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            join.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 8),
            join.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),

            cancel.trailingAnchor.constraint(equalTo: join.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: join.centerYAnchor),
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: 340, height: 168))

        self.panel = window
        self.field = field
        self.message = message
        self.joinButton = join
        return window
    }

    /// Same frosted Liquid Glass as the Wi-Fi popup. Older systems get the
    /// HUD blur instead of a solid panel.
    private func makeBackdrop() -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.appearance = NSAppearance(named: .darkAqua)
            #if compiler(>=6.4)  // SDK 27 symbol; see BarSurface
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            #endif
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        return effect
    }

    private func place(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + 40))
    }

    /// Cancel stays enabled while a join runs: the 30 s watchdog is the only
    /// other way out of a hung association, and abandoning the in-flight
    /// join is what `present` already does when a new prompt replaces it.
    private func setBusy(_ busy: Bool) {
        joining = busy
        field?.isEnabled = !busy
        joinButton?.isEnabled = !busy
        if busy {
            setMessage("Joining…", failure: false)
        }
    }

    private func setMessage(_ text: String?, failure: Bool) {
        guard let message else { return }
        message.stringValue = text ?? ""
        message.textColor = failure ? .systemRed : .secondaryLabelColor
    }

    private func dismiss(joined: Bool) {
        let callback = onFinish
        let restore = previousApp
        onFinish = nil
        previousApp = nil
        joining = false
        field?.stringValue = ""
        panel?.orderOut(nil)
        if restore?.bundleIdentifier != Bundle.main.bundleIdentifier {
            _ = restore?.activate()
        }
        callback?(joined)
    }

    /// Mid-join, the bumped `requestID` makes the completion below discard
    /// the result; the child runs on until it finishes or the watchdog
    /// fires, so a join cancelled late may still land — Lua only hears the
    /// close (exit code 2, from scheduleWifiPrompt) and the pill catches up
    /// on the wifi_change.
    @objc private func cancelPressed() {
        requestID += 1
        dismiss(joined: false)
    }

    @objc private func joinPressed() {
        guard !joining else { return }
        let password = field?.stringValue ?? ""
        guard !password.isEmpty else {
            setMessage("Enter the password for this network.", failure: true)
            panel?.makeFirstResponder(field)
            return
        }
        field?.stringValue = ""
        setBusy(true)
        let id = requestID
        let name = ssid
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WifiScan.join(ssid: name, password: password)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard id == self.requestID else { return }
                    if result.code == 0 {
                        self.dismiss(joined: true)
                    } else {
                        self.setBusy(false)
                        // The watchdog never saw a verdict, so do not blame
                        // the password for it.
                        let text = result.code == WifiScan.timedOutCode
                            ? "Timed out joining \(name)."
                            : "Couldn't join. Check the password and try again."
                        self.setMessage(text, failure: true)
                        self.panel?.makeFirstResponder(self.field)
                    }
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelPressed()
        return false
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            joinPressed()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelPressed()
            return true
        }
        return false
    }
}

/// Activating panel. Not `BarPanel`: that window is forbidden from becoming key.
private final class WifiPasswordWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
