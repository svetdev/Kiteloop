import AppKit
import Foundation
import KiteloopCore

enum UITestingSupport {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
    }

    static var isIntegrationTesting: Bool {
        ProcessInfo.processInfo.environment["INTEGRATION_TESTING"] == "1"
    }

    static var isUnitTesting: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static var isTesting: Bool {
        isUITesting || isUnitTesting
    }

    /// The folder Quick Start opens as its project. The temporary directory is
    /// the user's own, shared by every run, and a project keeps its chats — so a
    /// QA flow found every earlier run's messages there. Under an isolated
    /// `KITELOOP_HOME` it is a folder inside that home, gone with it.
    static func quickStartDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard environment[KiteloopHome.variable] != nil else { return FileManager.default.temporaryDirectory }
        let home = KiteloopHome.url(environment: environment, fallback: FileManager.default.temporaryDirectory)
        let folder = home.appending(path: "quick-start")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if environment["UI_TEST_SCENARIO"] == storyboardGateScenario {
            seedStoryboardGate(project: folder, home: home)
        }
        return folder
    }

    // MARK: - Two items at the approval gate, one with a kept QA storyboard

    /// Selects `seedStoryboardGate` for the QA flow of
    /// `approving-a-qa-item-shows-no-storyboard`. The flow's own process is
    /// sandboxed out of the throwaway home, so the app — which can write there —
    /// lays out what the flow needs as Quick Start opens it.
    static let storyboardGateScenario = "storyboardGate"
    static let storyboardGateCaptions = ["The Autopilot view opens", "The row shows a branch",
                                         "FAILED: The button is blue — got grey"]

    /// `project`'s BACKLOG.md with `qa-demo` and `plain-item` both awaiting
    /// approval, and a storyboard kept in `home` for `qa-demo` alone: one page
    /// and a picture per caption, laid out as `QAStoryboardArchive` keeps them.
    static func seedStoryboardGate(project: URL, home: URL) {
        let backlog = """
        # QA Backlog

        ## Epic: Now

        - [ ] qa-demo | Demo QA change | awaiting-approval
        - [ ] plain-item | Plain change | awaiting-approval

        """
        try? Data(backlog.utf8).write(to: project.appending(path: "BACKLOG.md"))
        let run = QAStoryboardArchive.destination(home: home, itemID: "qa-demo", runID: "run-1")
        let pictures = run.appending(path: "qa-demo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        var page = ["# qa-demo", ""]
        for (index, caption) in storyboardGateCaptions.enumerated() {
            let name = String(format: "%02d-step-%d.png", index + 1, index + 1)
            try? storyboardGatePicture(step: index + 1).write(to: pictures.appending(path: name))
            page += ["## \(index + 1). \(caption)", "", "![\(caption)](qa-demo/\(name))", ""]
        }
        try? Data(page.joined(separator: "\n").utf8).write(to: run.appending(path: "qa-demo.md"))
    }

    /// A picture told apart at a glance: a field of its own colour with the
    /// step's number on it.
    private static func storyboardGatePicture(step: Int) -> Data {
        let colors: [NSColor] = [.systemTeal, .systemPurple, .systemOrange]
        let image = NSImage(size: NSSize(width: 1200, height: 750), flipped: false) { rect in
            colors[(step - 1) % colors.count].setFill()
            rect.fill()
            ("Step \(step)" as NSString).draw(at: NSPoint(x: 80, y: 280), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 160), .foregroundColor: NSColor.white,
            ])
            return true
        }
        let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    static func makeMockRuntime() -> MockAgentRuntime {
        let mock = MockAgentRuntime()
        let scenario = ProcessInfo.processInfo.environment["UI_TEST_SCENARIO"] ?? "default"
        switch scenario {
        case "codeBlock": mock.events = codeBlockEvents
        case "permissionDenial": mock.events = permissionDenialEvents
        case "multiTurn": mock.events = multiTurnEvents
        case "underscoreEmphasis": mock.events = underscoreEmphasisEvents
        case "askHuman": mock.events = askHumanEvents
        case "slow":
            mock.events = defaultEvents
            mock.startDelay = 3_000_000_000
        default: mock.events = defaultEvents
        }
        return mock
    }

    static var defaultEvents: [StreamEvent] {
        [
            .assistantText("Hello! I'm ready to help with your code."),
            .result(.init(
                text: "Hello! I'm ready to help with your code.",
                costUSD: 0.001, durationMs: 500,
                inputTokens: 100, outputTokens: 25,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session-id", permissionDenials: []
            ))
        ]
    }

    /// A turn that asks the person a question and ends with it unanswered, so
    /// the agent is waiting on you — in the sidebar's Waiting on you row and
    /// its drawer — until the question is answered.
    static var askHumanEvents: [StreamEvent] {
        [
            .toolUse(id: "ask-1", name: "ask_human", input: #"{"question": "Which branch should I deploy?"}"#),
            .result(.init(
                text: "Waiting for your answer.",
                costUSD: 0.001, durationMs: 300,
                inputTokens: 80, outputTokens: 10,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session-id", permissionDenials: []
            ))
        ]
    }

    static var permissionDenialEvents: [StreamEvent] {
        [
            .toolUse(id: "t1", name: "Bash", input: #"{"command": "rm -rf /"}"#),
            .toolResult(id: "t1", output: "Permission denied"),
            .assistantText("I was unable to run that command due to permission restrictions."),
            .result(.init(
                text: "I was unable to run that command.",
                costUSD: 0.002, durationMs: 800,
                inputTokens: 150, outputTokens: 40,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session-id",
                permissionDenials: [.init(toolName: "Bash", detail: "rm -rf /")]
            ))
        ]
    }

    static var codeBlockEvents: [StreamEvent] {
        [
            .assistantText("Here's a Swift example:\n\n```swift\nfunc hello() {\n    print(\"Hello, World!\")\n}\n```\n"),
            .result(.init(
                text: "", costUSD: 0.001, durationMs: 400,
                inputTokens: 80, outputTokens: 30,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session-id", permissionDenials: []
            ))
        ]
    }

    /// A reply spelling emphasis with underscores beside an identifier that keeps its own.
    static var underscoreEmphasisEvents: [StreamEvent] {
        let reply = "Be _careful_ here: __never__ rename snake_case_name."
        return [
            .assistantText(reply),
            .result(.init(
                text: reply, costUSD: 0.001, durationMs: 400,
                inputTokens: 80, outputTokens: 20,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session-id", permissionDenials: []
            ))
        ]
    }

    static var multiTurnEvents: [StreamEvent] {
        [
            .thinking("Let me analyze this..."),
            .assistantText("I found the issue in your code."),
            .toolUse(id: "t2", name: "Read", input: #"{"file_path": "/tmp/test.swift"}"#),
            .toolResult(id: "t2", output: "func broken() {}"),
            .assistantText("The function needs a return type."),
            .result(.init(
                text: "The function needs a return type.",
                costUSD: 0.005, durationMs: 2000,
                inputTokens: 500, outputTokens: 100,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "mock-session-id", permissionDenials: []
            ))
        ]
    }
}
