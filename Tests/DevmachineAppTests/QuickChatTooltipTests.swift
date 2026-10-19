import XCTest
import SwiftUI
import AppKit
import DevmachineCore
@testable import DevmachineApp

private final class PacedChatRunner: ChatCommandRunning, @unchecked Sendable {
    let lines: [String]

    init(_ lines: [String]) {
        self.lines = lines
    }

    func stream(_ arguments: [String], line: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        for next in lines {
            line(next)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return 0
    }

    func run(_ arguments: [String]) async throws -> ChatCommandOutput {
        ChatCommandOutput(stdout: "", stderr: "", exitCode: 0)
    }

    func openSession(
        _ arguments: [String], line: @escaping @Sendable (String) -> Void,
        exited: @escaping @Sendable (Int32) -> Void
    ) throws -> any ChatSessionChannel {
        throw CancellationError()
    }
}

@MainActor
final class QuickChatTooltipTests: XCTestCase {
    private func tooltipManager(of view: NSView) -> AnyObject? {
        view.perform(NSSelectorFromString("_dynamicToolTipManager"))?.takeUnretainedValue()
    }

    private func host(_ root: some View) -> (NSWindow, NSView) {
        let window = QuickChatWindow(
            contentRect: NSRect(x: 0, y: 0, width: 728, height: 200),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: root)
        window.contentView = view
        window.orderFront(nil)
        return (window, view)
    }

    private func streamAnswerWithTools(into model: QuickChatModel) {
        model.text = "what is in this folder?"
        model.send()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    private func makeModel(failing: Bool = false) -> QuickChatModel {
        var lines = [ChatFixtures.started("q1")]
        for step in 0..<5 {
            lines.append(#"{"type":"tool","name":"Bash","summary":"ls \#(step)"}"#)
            lines.append(ChatFixtures.text("part \(step) "))
        }
        lines.append(failing ? #"{"type":"error","kind":"harness","message":"the agent stopped"}"# : ChatFixtures.done("q1"))
        let store = ChatStore(runner: PacedChatRunner(lines))
        store.workspaces = ["main"]
        return QuickChatModel(store: store)
    }

    func testThePanelHasNoSwiftUITooltipsWhileAnAnswerStreams() {
        let model = makeModel()
        let (window, view) = host(QuickChatPanelController.content(model: model, metrics: DMMetrics(scale: 1)) { _ in })
        streamAnswerWithTools(into: model)
        XCTAssertEqual(model.conversation?.messages.last?.tools.count, 5)
        XCTAssertNil(tooltipManager(of: view))
        window.orderOut(nil)
    }

    func testThePanelHasNoSwiftUITooltipsOnAFailedAnswer() {
        let model = makeModel(failing: true)
        let (window, view) = host(QuickChatPanelController.content(model: model, metrics: DMMetrics(scale: 1)) { _ in })
        streamAnswerWithTools(into: model)
        XCTAssertNotNil(model.conversation?.failure)
        XCTAssertNil(tooltipManager(of: view))
        window.orderOut(nil)
    }

    func testTheSameViewsKeepTheirTooltipsElsewhere() {
        let model = makeModel()
        let (window, view) = host(QuickChatCard(model: model))
        streamAnswerWithTools(into: model)
        XCTAssertNotNil(tooltipManager(of: view))
        window.orderOut(nil)
    }
}

/// The quick chat panel draws views from `Chats/` and `Components/`; one
/// plain `.help` there brings SwiftUI's tooltip bridge back into the panel.
final class DMHelpGuardTests: XCTestCase {
    private static let folders = ["Chats", "Components"]

    func testPanelViewsUseDMHelp() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DevmachineApp")
        var found: [String] = []
        for folder in Self.folders {
            let files = try FileManager.default.contentsOfDirectory(
                at: sources.appendingPathComponent(folder), includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DMHelp.swift" }
            XCTAssertFalse(files.isEmpty)
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where line.contains(".help(") {
                    found.append("\(folder)/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(found, [], "Use .dmHelp(_:) so the quick chat panel can turn tooltips off")
    }
}
