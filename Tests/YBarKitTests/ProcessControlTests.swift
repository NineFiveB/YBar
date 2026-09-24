import Foundation
import Testing
@testable import YBarKit

// The process-control verbs (`ybar start|stop|restart|status|autostart`) reach
// launchctl, LaunchServices and the user's real ~/Library/LaunchAgents, so what
// is exercised here is every decision they make *before* they touch any of
// that: which bundle to name, what to write into the login job, and how the
// arguments parse.

private func makeTemporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ybar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Finding YBar.app

@Suite struct AppBundleTests {
    @Test func bundledBinaryResolvesToItsBundle() {
        let executable = URL(fileURLWithPath: "/Users/me/Applications/YBar.app/Contents/MacOS/ybar")
        #expect(AppBundle.enclosingBundle(of: executable)?.path
            == "/Users/me/Applications/YBar.app")
    }

    @Test func bareBuildProductIsNotInABundle() {
        let executable = URL(fileURLWithPath: "/Users/me/.cache/ybar-build/debug/ybar")
        #expect(AppBundle.enclosingBundle(of: executable) == nil)
    }

    /// The `.app` suffix alone is not enough — a directory a user named
    /// `notes.app` would otherwise be handed to `open` as a bundle.
    @Test func appSuffixAloneIsNotABundle() {
        #expect(AppBundle.enclosingBundle(of: URL(fileURLWithPath: "/Users/me/notes.app/ybar")) == nil)
        #expect(AppBundle.enclosingBundle(
            of: URL(fileURLWithPath: "/Users/me/notes.app/Contents/bin/ybar")) == nil)
    }

    @Test func cellarPathRewritesToTheStableOptPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cellar = root.appendingPathComponent("Cellar/ybar/0.1.0/YBar.app")
        let opt = root.appendingPathComponent("opt/ybar/YBar.app")
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: opt, withIntermediateDirectories: true)
        #expect(AppBundle.stablePath(for: cellar).path == opt.path)
    }

    /// Without the opt link there is nothing stabler to point at, so the
    /// versioned path is kept rather than invented.
    @Test func cellarPathIsKeptWhenNoOptLinkExists() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cellar = root.appendingPathComponent("Cellar/ybar/0.1.0/YBar.app")
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        #expect(AppBundle.stablePath(for: cellar).path == cellar.path)
    }

    @Test func nonCellarPathIsUntouched() {
        let url = URL(fileURLWithPath: "/Users/me/Applications/YBar.app")
        #expect(AppBundle.stablePath(for: url).path == url.path)
    }

    /// The bundle we are already running from outranks every installed copy;
    /// after that it is the two `make app` destinations, then both Homebrew
    /// prefixes.
    @Test func searchOrderPrefersTheRunningBundle() {
        let home = URL(fileURLWithPath: "/Users/me")
        let executable = URL(fileURLWithPath: "/Applications/YBar.app/Contents/MacOS/ybar")
        let order = AppBundle.candidates(
            home: home, executable: executable, environment: [:]).map(\.path)
        #expect(order.first == "/Applications/YBar.app")
        #expect(order.contains("/Users/me/Applications/YBar.app"))
        #expect(order.contains("/opt/homebrew/opt/ybar/YBar.app"))
        #expect(order.contains("/usr/local/opt/ybar/YBar.app"))
    }

    @Test func searchOrderStartsAtHomeWhenNotBundled() {
        let home = URL(fileURLWithPath: "/Users/me")
        let executable = URL(fileURLWithPath: "/Users/me/.cache/ybar-build/debug/ybar")
        let order = AppBundle.candidates(
            home: home, executable: executable, environment: [:]).map(\.path)
        #expect(order.first == "/Users/me/Applications/YBar.app")
    }

    /// `brew shellenv` exports the prefix; trust it over the two guesses, so a
    /// Homebrew installed somewhere non-standard is still found.
    @Test func exportedHomebrewPrefixIsTriedFirst() {
        let order = AppBundle.candidates(
            home: URL(fileURLWithPath: "/Users/me"),
            executable: URL(fileURLWithPath: "/Users/me/.cache/ybar-build/debug/ybar"),
            environment: ["HOMEBREW_PREFIX": "/opt/brew"]).map(\.path)
        let brewEntries = order.filter { $0.contains("/opt/ybar/") }
        #expect(brewEntries.first == "/opt/brew/opt/ybar/YBar.app")
        #expect(brewEntries.count == 3)
    }

    /// A bare directory called `YBar.app` is not an app: `open` would refuse it
    /// with a LaunchServices diagnostic instead of a useful one.
    @Test func aDirectoryWithoutAnInfoPlistIsNotABundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("YBar.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        #expect(!AppBundle.isBundle(bundle))
        try Data().write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        #expect(AppBundle.isBundle(bundle))
    }

    /// The instance name is the binary's basename, so a second bar only has an
    /// autostartable binary if one was put inside the bundle for it.
    @Test func daemonBinaryIsNamedForTheInstance() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("YBar.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data().write(to: macOS.appendingPathComponent("ybar"))

        #expect(AppBundle.daemonBinary(in: bundle, instanceName: "ybar")?.path
            == macOS.appendingPathComponent("ybar").path)
        #expect(AppBundle.daemonBinary(in: bundle, instanceName: "bar2") == nil)
    }
}

// MARK: - The login job

@Suite struct LaunchAgentTests {
    /// The label docs/INSTALL.md has always told people to `launchctl bootout`.
    @Test func defaultInstanceKeepsTheDocumentedLabel() {
        #expect(LaunchAgent.label(instanceName: "ybar") == "com.ybar.YBar")
    }

    @Test func renamedInstanceGetsItsOwnLabel() {
        #expect(LaunchAgent.label(instanceName: "bar2") == "com.ybar.bar2")
    }

    @Test func plistLandsInTheUsersLaunchAgents() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(LaunchAgent.plistURL(instanceName: "ybar", home: home).path
            == "/Users/me/Library/LaunchAgents/com.ybar.YBar.plist")
    }

    @Test func plistCarriesTheKeysLaunchdNeeds() throws {
        let plist = LaunchAgent.plist(
            label: "com.ybar.YBar",
            programArguments: ["/Users/me/Applications/YBar.app/Contents/MacOS/ybar"],
            standardErrorPath: "/Users/me/Library/Logs/ybar.log")
        let data = try LaunchAgent.xmlData(plist)
        // launchd reads binary plists too, but a file users are told to read
        // and hand-edit has to be the XML one.
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "<?xml")

        let decoded = try #require(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        #expect(decoded["Label"] as? String == "com.ybar.YBar")
        #expect(decoded["RunAtLoad"] as? Bool == true)
        #expect(decoded["ProcessType"] as? String == "Interactive")
        #expect(decoded["StandardErrorPath"] as? String == "/Users/me/Library/Logs/ybar.log")
        // Only a real GUI session can host a bar that draws windows.
        #expect(decoded["LimitLoadToSessionType"] as? String == "Aqua")
        // A daemon that cannot boot at all exits 1, and KeepAlive restarts on
        // any non-zero code — this interval is what keeps that from becoming a
        // respawn storm at login.
        #expect(decoded["ThrottleInterval"] as? Int == 30)
        // What makes the Login Items row say "YBar" rather than a raw label.
        #expect(decoded["AssociatedBundleIdentifiers"] as? [String] == ["com.ybar.YBar"])
        // Restart after a crash, but never after a deliberate `ybar stop`,
        // which exits 0.
        let keepAlive = try #require(decoded["KeepAlive"] as? [String: Any])
        #expect(keepAlive["SuccessfulExit"] as? Bool == false)
    }

    /// ProgramArguments is an argv array, not a command line, so a config path
    /// with spaces in it needs no quoting and must survive verbatim.
    @Test func programArgumentsAreNotQuoted() throws {
        let config = "/Users/me/My Configs/ybarrc.lua"
        let plist = LaunchAgent.plist(
            label: "com.ybar.YBar",
            programArguments: ["/Users/me/Applications/YBar.app/Contents/MacOS/ybar", "-c", config],
            standardErrorPath: "/Users/me/Library/Logs/ybar.log")
        let data = try LaunchAgent.xmlData(plist)
        let decoded = try #require(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        #expect((decoded["ProgramArguments"] as? [String])?.last == config)
    }

    /// `autostart disable` puts the bar back up, and it has to come back on the
    /// config the login job was using rather than on whatever discovery picks.
    @Test func theJobsConfigIsRecoverableFromItsProgramArguments() {
        let withConfig: [String: Any] = [
            "ProgramArguments": ["/Applications/YBar.app/Contents/MacOS/ybar", "-c", "/a/b.lua"]
        ]
        #expect(LaunchAgent.configArgument(in: withConfig) == "/a/b.lua")
        let withLongFlag: [String: Any] = [
            "ProgramArguments": ["/Applications/YBar.app/Contents/MacOS/ybar", "--config", "/a/b.lua"]
        ]
        #expect(LaunchAgent.configArgument(in: withLongFlag) == "/a/b.lua")
        let plain: [String: Any] = [
            "ProgramArguments": ["/Applications/YBar.app/Contents/MacOS/ybar"]
        ]
        #expect(LaunchAgent.configArgument(in: plain) == nil)
        // A hand-edited plist with a dangling flag must not crash the verb.
        let dangling: [String: Any] = [
            "ProgramArguments": ["/Applications/YBar.app/Contents/MacOS/ybar", "-c"]
        ]
        #expect(LaunchAgent.configArgument(in: dangling) == nil)
        #expect(LaunchAgent.configArgument(in: ["Label": "com.ybar.YBar"]) == nil)
    }

    /// No `-c` at all when none was given: that absence is what lets the login
    /// job follow `current-theme` instead of pinning one config forever.
    @Test func programArgumentsOmitTheConfigWhenThereIsNone() {
        let binary = URL(fileURLWithPath: "/Applications/YBar.app/Contents/MacOS/ybar")
        #expect(LaunchAgent.programArguments(binary: binary, config: nil)
            == ["/Applications/YBar.app/Contents/MacOS/ybar"])
        let pinned = LaunchAgent.programArguments(binary: binary, config: "/a/b/../c.lua")
        #expect(pinned == ["/Applications/YBar.app/Contents/MacOS/ybar", "-c", "/a/c.lua"])
        // launchd expands no tilde, so it has to be gone by the time it is
        // written.
        let expanded = LaunchAgent.programArguments(binary: binary, config: "~/x.lua")
        #expect(expanded.last?.hasPrefix("/") == true)
        #expect(expanded.last?.contains("~") == false)
    }

    /// The login-job label is per-instance, but the app it is attributed to is
    /// always the one bundle — Login Items has to read "YBar" either way.
    @Test func attributionStaysTheBundleIdForARenamedInstance() throws {
        let plist = LaunchAgent.plist(
            label: LaunchAgent.label(instanceName: "bar2"),
            programArguments: ["/Applications/YBar.app/Contents/MacOS/bar2"],
            standardErrorPath: "/Users/me/Library/Logs/bar2.log")
        let decoded = try #require(PropertyListSerialization.propertyList(
            from: try LaunchAgent.xmlData(plist), options: [], format: nil) as? [String: Any])
        #expect(decoded["Label"] as? String == "com.ybar.bar2")
        #expect(decoded["AssociatedBundleIdentifiers"] as? [String] == ["com.ybar.YBar"])
    }

    @Test func plistReadsBackFromDisk() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("com.ybar.YBar.plist")
        let plist = LaunchAgent.plist(
            label: "com.ybar.YBar", programArguments: ["/bin/true"],
            standardErrorPath: "/dev/null")
        try LaunchAgent.xmlData(plist).write(to: url)
        #expect(LaunchAgent.read(at: url)?["Label"] as? String == "com.ybar.YBar")
        #expect(LaunchAgent.read(at: root.appendingPathComponent("absent.plist")) == nil)
    }

    /// Written as XML and read back through `LaunchAgent.read`, the way a
    /// hand-rolled ~/Library/LaunchAgents plist reaches the verbs.
    private func keepAlive(_ xml: String?) throws -> LaunchAgent.KeepAlivePolicy {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("com.ybar.YBar.plist")
        let keepAlive = xml.map { "<key>KeepAlive</key>\n\($0)" } ?? ""
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.ybar.YBar</string>
                <key>ProgramArguments</key>
                <array><string>/Applications/YBar.app/Contents/MacOS/ybar</string></array>
                <key>RunAtLoad</key>
                <true/>
                \(keepAlive)
            </dict>
            </plist>
            """.write(to: url, atomically: true, encoding: .utf8)
        let plist = try #require(LaunchAgent.read(at: url))
        return LaunchAgent.keepAlivePolicy(in: plist)
    }

    /// A hand-rolled agent usually says `<true/>`, which has launchd relaunch
    /// after ANY exit — a `stop` that only sent `--exit` reported success
    /// over a bar that was back within seconds.
    @Test func keepAliveShapesAreToldApart() throws {
        #expect(try keepAlive("<true/>") == .always)
        #expect(try keepAlive("<false/>") == .never)
        #expect(try keepAlive(nil) == .never)
        // What `enable` writes, and the other condition a clean exit fails.
        #expect(try keepAlive("<dict><key>SuccessfulExit</key><false/></dict>") == .onFailure)
        #expect(try keepAlive("<dict><key>Crashed</key><true/></dict>") == .onFailure)
        #expect(try keepAlive(
            "<dict><key>SuccessfulExit</key><false/><key>Crashed</key><true/></dict>") == .onFailure)
        // Conditions a clean exit satisfies; launchd ORs them, so one is enough.
        #expect(try keepAlive("<dict><key>SuccessfulExit</key><true/></dict>") == .always)
        #expect(try keepAlive("<dict><key>Crashed</key><false/></dict>") == .always)
        #expect(try keepAlive("""
            <dict><key>SuccessfulExit</key><false/>
            <key>PathState</key><dict><key>/tmp/flag</key><true/></dict></dict>
            """) == .always)
        #expect(try keepAlive("<dict/>") == .always)
        // Not a shape launchd documents; read on the safe side.
        #expect(try keepAlive("<string>yes</string>") == .always)
    }

    @Test func theEnabledPlistIsTheOneThatRespectsAStop() throws {
        let plist = LaunchAgent.plist(
            label: "com.ybar.YBar", programArguments: ["/bin/true"], standardErrorPath: "/dev/null")
        #expect(LaunchAgent.keepAlivePolicy(in: plist) == .onFailure)
        // Through the serializer too: Bools that come back as numbers are the
        // classic plist trap.
        let decoded = try #require(PropertyListSerialization.propertyList(
            from: try LaunchAgent.xmlData(plist), options: [], format: nil) as? [String: Any])
        #expect(LaunchAgent.keepAlivePolicy(in: decoded) == .onFailure)
    }

    /// The kickstart branches point at, and roll, the log the job actually
    /// writes — which a hand-written plist can put anywhere.
    @Test func theJobsLogIsReadFromItsPlist() throws {
        #expect(LaunchAgent.standardErrorPath(in: ["StandardErrorPath": "/Users/me/Library/Logs/bar.log"])
            == "/Users/me/Library/Logs/bar.log")
        #expect(LaunchAgent.standardErrorPath(in: ["StandardErrorPath": ""]) == nil)
        #expect(LaunchAgent.standardErrorPath(in: ["Label": "com.ybar.YBar"]) == nil)

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appendingPathComponent("ybar.log")
        let plistURL = root.appendingPathComponent("com.ybar.YBar.plist")
        #expect(LocalVerbs.jobLogURL(plistURL: plistURL, fallback: fallback).path == fallback.path)
        let custom = root.appendingPathComponent("elsewhere/bar.log")
        try LaunchAgent.xmlData(LaunchAgent.plist(
            label: "com.ybar.YBar", programArguments: ["/bin/true"],
            standardErrorPath: custom.path)).write(to: plistURL)
        #expect(LocalVerbs.jobLogURL(plistURL: plistURL, fallback: fallback).path == custom.path)
    }
}

// MARK: - Verb arguments

@Suite struct ProcessVerbArgumentTests {
    @Test func noOptionMeansNoConfig() {
        #expect(ConfigArgument.parse([]) == .absent)
    }

    @Test func bothSpellingsOfTheConfigOptionParse() {
        #expect(ConfigArgument.parse(["-c", "/a/b.lua"]) == .path("/a/b.lua"))
        #expect(ConfigArgument.parse(["--config", "/a/b.lua"]) == .path("/a/b.lua"))
    }

    /// A dangling `-c`, a stray word, or extra tokens have to print usage
    /// rather than be silently read as "no config".
    @Test func anythingElseIsMalformed() {
        #expect(ConfigArgument.parse(["-c"]) == .malformed)
        #expect(ConfigArgument.parse(["enable"]) == .malformed)
        #expect(ConfigArgument.parse(["-c", "/a/b.lua", "extra"]) == .malformed)
    }

    @Test func tildeAndRelativePathsAreMadeAbsolute() {
        #expect(LocalVerbs.absolutePath("~/x.lua").hasPrefix("/"))
        #expect(!LocalVerbs.absolutePath("x.lua").contains("/./"))
        #expect(LocalVerbs.absolutePath("/a/b/../c.lua") == "/a/c.lua")
    }

    /// Parsing is separated from doing precisely so this suite can cover every
    /// spelling without ever being one typo away from launching a real bar or
    /// writing a real login agent. Everything here goes through `parse`, which
    /// touches nothing.
    ///
    /// The message grammar must reach the daemon untouched: only bare verbs are
    /// claimed here.
    @Test func messageGrammarIsNotSwallowed() {
        #expect(LocalVerbs.parse([]) == nil)
        #expect(LocalVerbs.parse(["--set", "clock", "label=hi"]) == nil)
        #expect(LocalVerbs.parse(["--query", "bar"]) == nil)
        #expect(LocalVerbs.parse(["--trigger", "space_change"]) == nil)
        // `-m` means "this is a message", so it must not be unwrapped here.
        #expect(LocalVerbs.parse(["-m", "start"]) == nil)
        // Not a verb, even though it starts with one of their letters.
        #expect(LocalVerbs.parse(["starting"]) == nil)
    }

    @Test func wellFormedInvocationsParse() {
        #expect(LocalVerbs.parse(["start"]) == .start(.absent))
        #expect(LocalVerbs.parse(["start", "-c", "/a/b.lua"]) == .start(.path("/a/b.lua")))
        #expect(LocalVerbs.parse(["stop"]) == .stop)
        #expect(LocalVerbs.parse(["restart"]) == .restart(.absent))
        #expect(LocalVerbs.parse(["status"]) == .status)
        #expect(LocalVerbs.parse(["autostart", "enable"]) == .autostartEnable(.absent))
        #expect(LocalVerbs.parse(["autostart", "disable"]) == .autostartDisable)
        #expect(LocalVerbs.parse(["autostart", "status"]) == .autostartStatus)
        // Bare `autostart` reads as the non-destructive one.
        #expect(LocalVerbs.parse(["autostart"]) == .autostartStatus)
    }

    /// A wrong invocation is `.usage`, which exits 2 rather than 1 — the one
    /// distinction a shell wrapper acts on.
    @Test func malformedInvocationsAreUsageErrors() {
        func isUsage(_ argv: [String]) -> Bool {
            // `.usage?` matches through the Optional parse returns.
            if case .usage? = LocalVerbs.parse(argv) { return true }
            return false
        }
        #expect(isUsage(["stop", "extra"]))
        #expect(isUsage(["status", "extra"]))
        #expect(isUsage(["start", "-c"]))
        #expect(isUsage(["restart", "-c", "a", "b"]))
        #expect(isUsage(["autostart", "bogus"]))
        #expect(isUsage(["autostart", "disable", "x"]))
        #expect(isUsage(["autostart", "status", "x"]))
        #expect(isUsage(["autostart", "enable", "-c"]))
    }

    @Test func fieldsLineUp() {
        #expect(LocalVerbs.field("socket", "/tmp/x") == "  socket     /tmp/x")
        // A name longer than the column still keeps one separating space.
        #expect(LocalVerbs.field("autostartness", "x") == "  autostartness x")
    }
}

// MARK: - Reading launchctl

@Suite struct LaunchctlClassificationTests {
    /// launchctl exits with the errno-style number itself; `print`'s own output
    /// is not officially structured, so only the code may be read.
    @Test func printStatusMapsToJobState() {
        #expect(Launchctl.classify(printStatus: 0) == .loaded)
        #expect(Launchctl.classify(printStatus: 113) == .notLoaded)
        #expect(Launchctl.classify(printStatus: 112) == .noDomain)
        #expect(Launchctl.classify(printStatus: 5) == .unknown(5))
        // -1 is what Spawn.run reports when the spawn itself failed, which is
        // the code a machine with a deleted cwd actually produces.
        #expect(Launchctl.classify(printStatus: -1) == .unknown(-1))
    }

    /// 37 is EALREADY — the job is already loaded, which is the state the caller
    /// asked for. 5 is launchd's catch-all and must never be read as success.
    @Test func bootstrapSuccessIncludesAlreadyLoaded() {
        #expect(Launchctl.bootstrapSucceeded(0))
        #expect(Launchctl.bootstrapSucceeded(37))
        #expect(!Launchctl.bootstrapSucceeded(5))
        #expect(!Launchctl.bootstrapSucceeded(112))
        #expect(!Launchctl.bootstrapSucceeded(134))
    }

    /// Nothing to remove is the end state a caller wanted, and 36 is cosmetic —
    /// the job does go away.
    @Test func bootoutSuccessIncludesNothingToRemove() {
        #expect(Launchctl.bootoutSucceeded(0))
        #expect(Launchctl.bootoutSucceeded(3))
        #expect(Launchctl.bootoutSucceeded(36))
        #expect(Launchctl.bootoutSucceeded(113))
        #expect(!Launchctl.bootoutSucceeded(5))
        #expect(!Launchctl.bootoutSucceeded(112))
    }

    /// Captured from `launchctl print gui/<uid>/<label>`: the pid sits on a
    /// line of its own, `pid-local endpoints = {` opens a block further down,
    /// and the nested blocks carry a `state` of their own.
    static let runningJob = """
        gui/501/com.ybar.YBar = {
        \tactive count = 7
        \tpath = /Users/me/Library/LaunchAgents/com.ybar.YBar.plist
        \ttype = LaunchAgent
        \tstate = running
        \tbundle id = com.ybar.YBar

        \tprogram = /Users/me/Applications/YBar.app/Contents/MacOS/ybar
        \targuments = {
        \t\t/Users/me/Applications/YBar.app/Contents/MacOS/ybar
        \t}

        \tdomain = gui/501 [100015]
        \tminimum runtime = 1
        \texit timeout = 5
        \truns = 1
        \tpid = 1299
        \timmediate reason = non-ipc demand
        \tlast exit code = (never exited)

        \tpid-local endpoints = {
        \t\t"com.apple.tsm.portname" = {
        \t\t\tstate = active
        \t\t\tactive count = 1
        \t\t}
        \t}
        \tjob state = running
        }
        """

    static let downJob = """
        gui/501/com.ybar.YBar = {
        \tactive count = 0
        \tpath = /Users/me/Library/LaunchAgents/com.ybar.YBar.plist
        \ttype = LaunchAgent
        \tstate = not running

        \tprogram = /Users/me/Applications/YBar.app/Contents/MacOS/ybar
        \truns = 3
        \tlast exit code = 0
        }
        """

    static let missingJob = """
        Bad request.
        Could not find service "com.ybar.YBar" in domain for user gui: 501
        """

    /// The exit code cannot tell a loaded job that is down from one whose
    /// process is alive and silent; the pid line can.
    @Test func pidIsReadFromPrintOutput() {
        #expect(Launchctl.pid(inPrintOutput: Self.runningJob) == 1299)
        #expect(Launchctl.pid(inPrintOutput: Self.downJob) == nil)
        #expect(Launchctl.pid(inPrintOutput: Self.missingJob) == nil)
        #expect(Launchctl.pid(inPrintOutput: "") == nil)
        // A line that only starts like the pid line, and pids launchd never prints.
        #expect(Launchctl.pid(inPrintOutput: "\tpid = \n\tpid-local endpoints = {\n") == nil)
        #expect(Launchctl.pid(inPrintOutput: "\tpid = 0\n") == nil)
        #expect(Launchctl.pid(inPrintOutput: "\tpid = 12a\n") == nil)
    }

    /// The shape `enable` writes says nothing extra; the two that change what
    /// `stop` and a crash do are named.
    @Test func autostartSummaryNamesAKeepAliveThatUndoesAStop() {
        let label = "com.ybar.YBar"
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: true, state: .loaded,
                                            policy: .onFailure)
            == "enabled (job \(label) loaded)")
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: true, state: .loaded,
                                            policy: .always)
            == "enabled (job \(label) loaded, KeepAlive: always)")
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: true, state: .notLoaded,
                                            policy: .always)
            .hasSuffix("KeepAlive: always)"))
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: true, state: .loaded,
                                            policy: .never)
            .contains("KeepAlive: off"))
        // Nothing to add about a job whose plist is gone.
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: false, state: .loaded,
                                            policy: .always)
            == "disabled (job \(label) is still loaded until you log out)")
    }

    @Test func autostartSummaryCoversEveryCombination() {
        let label = "com.ybar.YBar"
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: true, state: .loaded)
            .hasPrefix("enabled"))
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: true, state: .notLoaded)
            .contains("next login"))
        // A job loaded from a plist that has since been deleted survives until
        // the user logs out — reporting it as plain "disabled" would be a lie.
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: false, state: .loaded)
            .contains("still loaded"))
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: false, state: .notLoaded)
            == "disabled")
        // Over ssh or under sudo there is no GUI domain to ask, and claiming
        // "disabled" would send the user chasing a problem they do not have.
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: true, state: .noDomain)
            .hasPrefix("unknown"))
        // An unexplained launchctl failure must not read the same as a machine
        // that genuinely has no agent — an opaque "disabled" with nowhere to
        // look is the exact failure this verb exists to prevent.
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: true, state: .unknown(5))
            .hasPrefix("unknown"))
        #expect(LocalVerbs.autostartSummary(label: label, hasPlist: false, state: .unknown(-1))
            .hasPrefix("unknown"))
    }

    /// launchd never rotates what it captures, and one failing Lua callback
    /// writes a line per tick forever under a job nobody is watching.
    @Test func theLogIsRolledOnlyOnceItIsBig() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("ybar.log")
        let rolled = root.appendingPathComponent("ybar.log.1")

        try Data(repeating: 0x61, count: 1024).write(to: log)
        LocalVerbs.rotateLog(at: log)
        #expect(FileManager.default.fileExists(atPath: log.path))
        #expect(!FileManager.default.fileExists(atPath: rolled.path))

        try Data(repeating: 0x61, count: 2 * 1024 * 1024).write(to: log)
        LocalVerbs.rotateLog(at: log)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: rolled.path))

        // A second roll replaces the previous .1 rather than failing on it.
        try Data(repeating: 0x62, count: 2 * 1024 * 1024).write(to: log)
        LocalVerbs.rotateLog(at: log)
        #expect(FileManager.default.fileExists(atPath: rolled.path))
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    /// A `-c` the user typed is an assertion about a file. Nothing downstream
    /// catches a missing one: the daemon logs a line, keeps running with the
    /// socket bound, and the bar comes up empty — which `autostart enable`
    /// would then freeze into every login.
    @Test func aConfigThatIsNotThereIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("ybarrc.lua")
        try Data().write(to: present)

        #expect(LocalVerbs.configExists(.absent))
        #expect(LocalVerbs.configExists(.path(present.path)))
        #expect(!LocalVerbs.configExists(.path(root.appendingPathComponent("typo.lua").path)))
    }
}

// MARK: - The boot grace and the kickstart waits

/// The wait behind `start` and `restart`'s grace runs on a clock and a sleep
/// it is handed, so what is pinned here is the shape of the wait itself: how
/// long a silent process gets, when it is read as wedged, and when the notice
/// fires.
@Suite struct WaitTests {
    /// Scripted time: sleeping is the only thing that moves it.
    final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        var elapsed: TimeInterval { now.timeIntervalSinceReferenceDate }
        func sleep(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// A bar that binds its socket during the grace is a live bar: the wait
    /// ends the moment it answers, and nothing was said about it.
    @Test func aBarThatBindsDuringTheGraceIsLeftAlone() {
        let clock = Clock()
        var probes = 0
        var notices = 0
        let answered = LocalVerbs.poll(
            timeout: LocalVerbs.bootGrace, noticeAfter: LocalVerbs.noticeAfter, every: 1,
            clock: { clock.now }, sleep: clock.sleep, notice: { notices += 1 }
        ) {
            probes += 1
            return probes == 3
        }
        #expect(answered)
        #expect(probes == 3)
        #expect(clock.elapsed == 2)
        #expect(notices == 0)
    }

    /// One that stays silent is read as wedged only once the whole grace has
    /// passed — with one last look at the deadline — and is mentioned once.
    @Test func aBarThatStaysSilentIsReadAsWedgedAfterTheGrace() {
        let clock = Clock()
        var probes = 0
        var notices = 0
        let answered = LocalVerbs.poll(
            timeout: LocalVerbs.bootGrace, noticeAfter: LocalVerbs.noticeAfter, every: 1,
            clock: { clock.now }, sleep: clock.sleep, notice: { notices += 1 }
        ) {
            probes += 1
            return false
        }
        #expect(!answered)
        #expect(clock.elapsed == LocalVerbs.bootGrace)
        #expect(probes == Int(LocalVerbs.bootGrace) + 1)
        #expect(notices == 1)
    }

    /// The last look counts: a socket bound exactly at the deadline answers.
    @Test func theLastLookIsAtTheDeadline() {
        let clock = Clock()
        let answered = LocalVerbs.poll(
            timeout: 3, every: 1, clock: { clock.now }, sleep: clock.sleep
        ) { clock.elapsed >= 3 }
        #expect(answered)
        #expect(clock.elapsed == 3)
    }

    /// The numbers. A booting bar gets the same allowance as one this verb
    /// launched — the Metal device and the shader compile come before the
    /// bind — and a kickstart's -k retry gets that allowance too, so a job
    /// that never comes up costs 45 s + 15 s rather than 90.
    @Test func theGraceAndTheRetryAreBounded() {
        #expect(LocalVerbs.bootGrace == LocalVerbs.readyTimeout)
        #expect(LocalVerbs.kickstartRetryTimeout == LocalVerbs.readyTimeout)
        #expect(LocalVerbs.launchdReadyTimeout + LocalVerbs.kickstartRetryTimeout == 60)
    }

    /// The defaults are real time: a caller with no scripted clock sleeps.
    @Test func theDefaultsRunOnRealTime() {
        let started = Date()
        #expect(!LocalVerbs.poll(timeout: 0.05, every: 0.01) { false })
        #expect(Date().timeIntervalSince(started) >= 0.05)
    }
}

// MARK: - theme use

@Suite struct ThemeUseTests {
    /// With no bar running, `use` goes through `start`. For the default
    /// instance that is a plain `start`: the recorded name is what discovery
    /// picks up, and a loaded login job is kickstarted rather than bypassed
    /// by an unmanaged `-c` copy. `-c` stays for a renamed instance (its
    /// discovery never reads current-theme) and for a theme that only
    /// YBAR_THEME_ROOTS can see.
    @Test func startIsPlainWhenDiscoveryWouldFindTheTheme() {
        let entry = URL(fileURLWithPath: "/Users/me/.config/ybar/themes/darxk/ybarrc.lua")
        #expect(ThemeVerbs.startArguments(entry: entry, instanceName: "ybar", discoverable: true)
            == ["start"])
        #expect(ThemeVerbs.startArguments(entry: entry, instanceName: "ybar", discoverable: false)
            == ["start", "-c", entry.path])
        #expect(ThemeVerbs.startArguments(entry: entry, instanceName: "bar2", discoverable: true)
            == ["start", "-c", entry.path])
    }
}

// MARK: - Help text

@Suite struct HelpTextTests {
    /// The help text is the only place the verbs are advertised, and it lives in
    /// a different file from the dispatch table — so it is exactly the thing
    /// that drifts.
    @Test func helpMentionsEveryVerb() {
        for verb in LocalVerbs.verbs {
            #expect(CLIClient.helpText.contains("ybar \(verb)"),
                    "help text never mentions `ybar \(verb)`")
        }
    }
}

// MARK: - Config discovery

@Suite struct ThemeDiscoveryTests {
    /// Writes a theme directory with an entry file and returns the entry path.
    private func makeTheme(in root: URL, named name: String,
                           entry: String = "ybarrc.lua") throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(entry)
        try Data().write(to: file)
        return file
    }

    /// The whole point: a bar started with no `-c` — by the login agent, or by
    /// `ybar start` — picks up the theme the user selected.
    @Test func recordedThemeBeatsTheDefaultConfig() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/ybar")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Data().write(to: configDirectory.appendingPathComponent("ybarrc.lua"))
        let entry = try makeTheme(in: configDirectory.appendingPathComponent("themes"), named: "darxk")
        try "darxk\n".write(to: configDirectory.appendingPathComponent("current-theme"),
                            atomically: true, encoding: .utf8)

        let found = ConfigLocator.locate(
            explicitPath: nil, instanceName: "ybar", environment: [:], home: home)
        #expect(found?.path == entry.path)
    }

    @Test func jsoncThemesResolveToo() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/ybar")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let entry = try makeTheme(in: configDirectory.appendingPathComponent("themes"),
                                  named: "jsonc-demo", entry: "ybar.jsonc")
        try "jsonc-demo".write(to: configDirectory.appendingPathComponent("current-theme"),
                               atomically: true, encoding: .utf8)

        let found = ConfigLocator.locate(
            explicitPath: nil, instanceName: "ybar", environment: [:], home: home)
        #expect(found?.path == entry.path)
    }

    /// A theme the user deleted must not leave the bar configless.
    @Test func staleThemeNameFallsThroughToDiscovery() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/ybar")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let fallback = configDirectory.appendingPathComponent("ybarrc.lua")
        try Data().write(to: fallback)
        try "deleted-theme".write(to: configDirectory.appendingPathComponent("current-theme"),
                                  atomically: true, encoding: .utf8)

        let found = ConfigLocator.locate(
            explicitPath: nil, instanceName: "ybar", environment: [:], home: home)
        #expect(found?.path == fallback.path)
    }

    /// A renamed binary is an independent bar; it must not be hijacked into
    /// ybar's theme.
    @Test func renamedInstanceIgnoresTheDefaultInstancesTheme() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ybarDirectory = home.appendingPathComponent(".config/ybar")
        try FileManager.default.createDirectory(at: ybarDirectory, withIntermediateDirectories: true)
        _ = try makeTheme(in: ybarDirectory.appendingPathComponent("themes"), named: "darxk")
        try "darxk".write(to: ybarDirectory.appendingPathComponent("current-theme"),
                          atomically: true, encoding: .utf8)
        let otherDirectory = home.appendingPathComponent(".config/bar2")
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let own = otherDirectory.appendingPathComponent("bar2rc.lua")
        try Data().write(to: own)

        let found = ConfigLocator.locate(
            explicitPath: nil, instanceName: "bar2", environment: [:], home: home)
        #expect(found?.path == own.path)
    }

    /// `-c` is still the last word on which config runs.
    @Test func explicitPathOutranksTheRecordedTheme() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/ybar")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        _ = try makeTheme(in: configDirectory.appendingPathComponent("themes"), named: "darxk")
        try "darxk".write(to: configDirectory.appendingPathComponent("current-theme"),
                          atomically: true, encoding: .utf8)
        let explicit = home.appendingPathComponent("explicit.lua")
        try Data().write(to: explicit)

        let found = ConfigLocator.locate(
            explicitPath: explicit.path, instanceName: "ybar", environment: [:], home: home)
        #expect(found?.path == explicit.path)
    }

    /// A hand-edited state file naming `../..` must not walk out of the theme
    /// roots.
    @Test func themeNameCannotEscapeItsRoot() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/ybar")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let fallback = configDirectory.appendingPathComponent("ybarrc.lua")
        try Data().write(to: fallback)
        try "../..".write(to: configDirectory.appendingPathComponent("current-theme"),
                          atomically: true, encoding: .utf8)

        #expect(ThemeCatalog.currentName(home: home) == nil)
        let found = ConfigLocator.resolve(
            explicitPath: nil, instanceName: "ybar", environment: [:], home: home)
        #expect(found?.url.path == fallback.path)
        #expect(found?.theme == nil)
    }

    /// The two remaining escape shapes. `/` is covered above; these are the
    /// ones a hand-edited state file reaches. The rule lives in
    /// `ThemeCatalog.currentName`, so the daemon's discovery sees the same.
    @Test func dotAndDotDotAreRejectedAsThemeNames() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/ybar")
        try FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true)
        let state = configDirectory.appendingPathComponent("current-theme")
        for name in [".", "..", "a\\b", "  ", ""] {
            try name.write(to: state, atomically: true, encoding: .utf8)
            #expect(ThemeCatalog.currentName(home: home) == nil)
        }
    }

    /// The tiers the theme tier was inserted ahead of. They were untested
    /// before this change and are exactly what a regression would land on.
    @Test func theSketchybarDiscoveryOrderStillHolds() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/ybar")
        let xdgDirectory = home.appendingPathComponent("xdg/ybar")
        try FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: xdgDirectory, withIntermediateDirectories: true)

        // Home dot-file only.
        let dotfile = home.appendingPathComponent(".ybarrc")
        try Data().write(to: dotfile)
        #expect(ConfigLocator.locate(explicitPath: nil, instanceName: "ybar",
                                     environment: [:], home: home)?.path == dotfile.path)

        // ~/.config beats the home dot-file, and .lua beats the bare script.
        let bare = configDirectory.appendingPathComponent("ybarrc")
        try Data().write(to: bare)
        #expect(ConfigLocator.locate(explicitPath: nil, instanceName: "ybar",
                                     environment: [:], home: home)?.path == bare.path)
        let lua = configDirectory.appendingPathComponent("ybarrc.lua")
        try Data().write(to: lua)
        #expect(ConfigLocator.locate(explicitPath: nil, instanceName: "ybar",
                                     environment: [:], home: home)?.path == lua.path)

        // XDG_CONFIG_HOME outranks both.
        let xdg = xdgDirectory.appendingPathComponent("ybarrc.lua")
        try Data().write(to: xdg)
        #expect(ConfigLocator.locate(
            explicitPath: nil, instanceName: "ybar",
            environment: ["XDG_CONFIG_HOME": home.appendingPathComponent("xdg").path],
            home: home
        )?.path == xdg.path)

        // An explicit path that does not exist resolves to nothing rather than
        // falling through — the daemon reports it instead of running a config
        // the user did not ask for.
        #expect(ConfigLocator.locate(explicitPath: "/nope/ybarrc.lua", instanceName: "ybar",
                                     environment: [:], home: home) == nil)
    }

    @Test func noStateFileMeansNormalDiscovery() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/ybar")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let fallback = configDirectory.appendingPathComponent("ybarrc.lua")
        try Data().write(to: fallback)

        #expect(ThemeCatalog.currentName(home: home) == nil)
        let found = ConfigLocator.locate(
            explicitPath: nil, instanceName: "ybar", environment: [:], home: home)
        #expect(found?.path == fallback.path)
    }
}

// MARK: - autostart enable

@Suite struct AutostartEnableTests {
    /// Without `-c` the login job starts on whatever discovery finds, so
    /// `enable` refuses when there is nothing to find — and it does so before
    /// the running bar is handed over, so a refusal leaves the screen alone.
    @Test func enableWithoutAConfigNeedsSomethingDiscoverable() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        func refusal() -> String? {
            LocalVerbs.nothingToStart(instanceName: "ybar", home: home, environment: [:])
        }
        #expect(refusal()?.contains("autostart enable -c") == true)

        // A recorded theme that resolves is something to start.
        let configDirectory = home.appendingPathComponent(".config/ybar")
        let theme = configDirectory.appendingPathComponent("themes/darxk")
        try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
        try Data().write(to: theme.appendingPathComponent("ybarrc.lua"))
        try "darxk\n".write(to: configDirectory.appendingPathComponent("current-theme"),
                            atomically: true, encoding: .utf8)
        #expect(refusal() == nil)

        // So is a plain config, with no theme recorded at all.
        try FileManager.default.removeItem(at: configDirectory.appendingPathComponent("current-theme"))
        #expect(refusal() != nil)
        try Data().write(to: configDirectory.appendingPathComponent("ybarrc.lua"))
        #expect(refusal() == nil)
    }
}
