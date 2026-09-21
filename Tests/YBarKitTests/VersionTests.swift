import Foundation
import Testing
@testable import YBarKit

/// `ybar --version` names the build it came from: the bundle's
/// CFBundleVersion (a short commit hash stamped at assembly time, or the
/// release build number) rides along in parentheses when there is one.
@Suite struct VersionTests {
    @Test func bareExecutableReportsOnlyTheVersion() {
        #expect(Version.display(current: "0.1.0", build: nil) == "0.1.0")
    }

    @Test func bundleBuildIsAppendedInParentheses() {
        #expect(Version.display(current: "0.1.0", build: "a1b2c3d") == "0.1.0 (a1b2c3d)")
        #expect(Version.display(current: "0.1.0", build: "1") == "0.1.0 (1)")
    }

    @Test func liveDisplayStartsWithTheCurrentVersion() {
        // Whatever the test host's bundle says, the version leads.
        #expect(Version.display.hasPrefix(Version.current))
        if let build = Version.build {
            #expect(Version.display == "\(Version.current) (\(build))")
        } else {
            #expect(Version.display == Version.current)
        }
    }
}
