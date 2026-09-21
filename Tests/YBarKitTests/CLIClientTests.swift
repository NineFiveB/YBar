import Foundation
import Testing
@testable import YBarKit

/// The CLI role's trigger-environment fold (the AeroSpace / yabai hook fast
/// path), driven with an injected environment instead of the process's own.
/// Same contract the Windows port pins in socket_tests.cpp.
@Suite struct TriggerEnvironmentFoldTests {
    private let environment = [
        "AEROSPACE_FOCUSED_WORKSPACE": "3",
        "AEROSPACE_PREV_WORKSPACE": "1",
        "YABAI_SPACE_ID": "7",
        "YABAI_RECENT_SPACE_ID": "2",
        "KOMOREBI_FOCUSED_WORKSPACE": "V",
        "UNRELATED": "x",
    ]

    @Test func workspaceKeysFoldIntoATrigger() {
        let folded = CLIClient.foldTriggerEnvironment(
            into: ["--trigger", "aerospace_workspace_change"], environment: environment)
        #expect(folded == [
            "--trigger", "aerospace_workspace_change",
            "FOCUSED_WORKSPACE=3", "PREV_WORKSPACE=1",
            "RECENT_SPACE_ID=2", "SPACE_ID=7",
        ])
        // Only the two hook families fold; anything else stays out of the payload.
        #expect(!folded.contains { $0.hasPrefix("KOMOREBI") || $0.hasPrefix("UNRELATED") })
    }

    @Test func explicitTokensWinOverTheEnvironment() {
        let folded = CLIClient.foldTriggerEnvironment(
            into: ["--trigger", "ws", "FOCUSED_WORKSPACE=9", "SPACE_ID=0"], environment: environment)
        #expect(folded.filter { $0.hasPrefix("FOCUSED_WORKSPACE=") } == ["FOCUSED_WORKSPACE=9"])
        #expect(folded.filter { $0.hasPrefix("SPACE_ID=") } == ["SPACE_ID=0"])
        // The keys the caller did not spell out still arrive.
        #expect(folded.contains("PREV_WORKSPACE=1"))
        #expect(folded.contains("RECENT_SPACE_ID=2"))
    }

    @Test func otherMessagesAndEmptyEnvironmentsPassThrough() {
        #expect(CLIClient.foldTriggerEnvironment(into: ["--set", "a", "b=1"], environment: environment)
                == ["--set", "a", "b=1"])
        #expect(CLIClient.foldTriggerEnvironment(into: ["--trigger", "ws"], environment: [:])
                == ["--trigger", "ws"])
        #expect(CLIClient.foldTriggerEnvironment(into: [], environment: environment) == [])
    }

    @Test func yabaiPrefixIsStrippedNotTheWholeName() {
        let folded = CLIClient.foldTriggerEnvironment(
            into: ["--trigger", "yabai_space_change"], environment: ["YABAI_WINDOW_ID": "42"])
        #expect(folded.last == "WINDOW_ID=42")
    }
}
