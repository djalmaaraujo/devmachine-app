import XCTest
import DevmachineCore
@testable import DevmachineApp

private final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        lock.lock()
        recorded.append(args)
        lock.unlock()
        return ""
    }

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.compactMap(\.last)
    }
}

@MainActor
final class EndSessionTests: XCTestCase {
    private let acme = Workspace(name: "acme", alias: "acme-devmachine")
    private var runner: RecordingRunner!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        runner = RecordingRunner()
        model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [acme]
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition never became true")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testASingleRemoteSessionAsksToEndIt() {
        model.clickSession(SessionRef(alias: acme.alias, name: "dash"))

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .askToEndSession)
        XCTAssertEqual(model.pendingEndSession, SessionEndRequest(
            item: .session(alias: acme.alias, name: "dash"), name: "dash", place: "acme"))
    }

    func testASingleLocalSessionAsksToEndItOnThisMac() {
        model.addLocalSession(path: "/Users/alice/dev/beta")
        model.selection = .localSession(name: "beta", path: "/Users/alice/dev/beta")

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .askToEndSession)
        XCTAssertEqual(model.pendingEndSession?.name, "beta")
        XCTAssertEqual(model.pendingEndSession?.place, "This Mac")
    }

    func testDeletingAnUnselectedRemoteSessionAsksWithTheSameRequest() {
        model.clickSession(SessionRef(alias: acme.alias, name: "api"))

        model.askToEndSession(.session(alias: acme.alias, name: "dash"))

        XCTAssertEqual(model.pendingEndSession, SessionEndRequest(
            item: .session(alias: acme.alias, name: "dash"), name: "dash", place: "acme"))
    }

    func testAFocusedPreviewTabClosesInsteadOfEndingTheSession() {
        model.clickSession(SessionRef(alias: acme.alias, name: "dash"))
        let tab = UUID()

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true, focusedPreview: tab), .closePreview(tab))
        XCTAssertNil(model.pendingEndSession)
    }

    func testAFocusedPreviewInAnotherWindowKeepsTheDefaultClose() {
        XCTAssertEqual(model.handleCloseCommand(inMainWindow: false, focusedPreview: UUID()), .closeWindow)
    }

    func testAPreviewTagNamesItsTab() {
        let tab = UUID()

        XCTAssertEqual(FocusedPreview.id(fromTag: FocusedPreview.tag(for: tab)), tab)
        XCTAssertNil(FocusedPreview.id(fromTag: FocusedTerminal.tag(for: .remote(alias: acme.alias, session: "dash"))))
        XCTAssertNil(FocusedPreview.id(fromTag: "preview:not-a-uuid"))
    }

    func testTheSelectedSessionOwnsThePreviews() {
        model.clickSession(SessionRef(alias: acme.alias, name: "dash"))
        XCTAssertEqual(PreviewStore.shared.owner, SessionRef(alias: acme.alias, name: "dash"))

        model.addLocalSession(path: "/Users/alice/dev/beta")
        model.selection = .localSession(name: "beta", path: "/Users/alice/dev/beta")
        XCTAssertEqual(PreviewStore.shared.owner, SessionRef(alias: Workspace.local.alias, name: "beta"))

        model.selection = nil
        XCTAssertNil(PreviewStore.shared.owner)
    }

    func testAGridOfSessionsKeepsTheDefaultClose() {
        let dash = SessionRef(alias: acme.alias, name: "dash")
        let api = SessionRef(alias: acme.alias, name: "api")
        model.clickSession(dash)
        model.activePage = .stack([dash, api])

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeWindow)
        XCTAssertNil(model.pendingEndSession)
    }

    func testSeveralSelectedSessionsKeepTheDefaultClose() {
        model.clickSession(SessionRef(alias: acme.alias, name: "dash"))
        model.cmdClickSession(SessionRef(alias: acme.alias, name: "api"))

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeWindow)
        XCTAssertNil(model.pendingEndSession)
    }

    func testNoSelectionKeepsTheDefaultClose() {
        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeWindow)
        XCTAssertNil(model.pendingEndSession)
    }

    func testAPageOverTheSessionKeepsTheDefaultClose() {
        model.clickSession(SessionRef(alias: acme.alias, name: "dash"))
        model.activePage = .stats

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeWindow)
    }

    func testAnotherWindowKeepsTheDefaultClose() {
        model.clickSession(SessionRef(alias: acme.alias, name: "dash"))

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: false), .closeWindow)
        XCTAssertNil(model.pendingEndSession)
    }

    func testTheOperatorSessionIsNeverOfferedToEnd() {
        model.selection = .localSession(name: Workspace.operatorSession, path: "/Users/alice/dev/ops")

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeWindow)
        XCTAssertNil(model.pendingEndSession)
    }

    func testConfirmingKillsThatRemoteSession() async throws {
        model.clickSession(SessionRef(alias: acme.alias, name: "dash"))
        _ = model.handleCloseCommand(inMainWindow: true)

        model.confirmEndSession()

        XCTAssertNil(model.pendingEndSession)
        try await waitUntil { self.runner.commands.contains(RemoteCommands.killSession(name: "dash")) }
        try await waitUntil { self.model.selection == nil }
    }

    func testConfirmingRemovesThatLocalSession() {
        model.addLocalSession(path: "/Users/alice/dev/beta")
        model.selection = .localSession(name: "beta", path: "/Users/alice/dev/beta")
        _ = model.handleCloseCommand(inMainWindow: true)

        model.confirmEndSession()

        XCTAssertNil(model.pendingEndSession)
        XCTAssertEqual(model.localSessions.map(\.handle), [Workspace.operatorSession])
        XCTAssertNil(model.selection)
    }

    func testCancellingEndsNothing() async throws {
        let item = SidebarItem.session(alias: acme.alias, name: "dash")
        model.clickSession(SessionRef(alias: acme.alias, name: "dash"))
        _ = model.handleCloseCommand(inMainWindow: true)

        model.cancelEndSession()
        model.confirmEndSession()

        XCTAssertNil(model.pendingEndSession)
        XCTAssertEqual(model.selection, item)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(runner.commands.contains(RemoteCommands.killSession(name: "dash")))
    }
}
