import XCTest
import DevmachineCore
@testable import DevmachineApp

private final class QuietRunner: CommandRunner, @unchecked Sendable {
    func run(executable: String, args: [String], environment: [String: String]?) throws -> String { "" }
}

@MainActor
final class CenterTabsTests: XCTestCase {
    private let dash = SidebarItem.session(alias: "acme-devmachine", name: "dash")
    private let api = SidebarItem.session(alias: "acme-devmachine", name: "api")
    private let shell = SidebarItem.localSession(name: "shell", path: "/Users/alice/dev")

    private var viewer: FileViewerStore!

    private func model() -> AppModel {
        let model = AppModel(services: fixtureServices())
        viewer = FileViewerStore(host: HostRunner(local: QuietRunner()))
        model.fileViewer = viewer
        viewer.onOpen = { [weak model] path in model?.fileOpened(path: path) }
        return model
    }

    func testSelectingASessionOpensItsTabOnce() {
        let model = model()
        model.selection = dash
        model.selection = api
        model.selection = dash
        XCTAssertEqual(model.openTabs.items, [.session(dash), .session(api)])
        XCTAssertTrue(model.isSelected(tab: .session(dash)))
        XCTAssertFalse(model.isSelected(tab: .session(api)))
        XCTAssertEqual(model.title(for: .session(dash)), "dash")
    }

    func testADeletedSessionLosesItsTab() {
        let model = model()
        model.selection = dash
        model.selection = api
        model.forgetDeletedSession(SessionRef(alias: "acme-devmachine", name: "dash"))
        XCTAssertEqual(model.openTabs.items, [.session(api)])
        XCTAssertEqual(model.selection, api)
    }

    func testARenamedSessionKeepsItsTabUnderTheNewName() {
        let model = model()
        model.selection = dash
        model.fileOpened(path: "/home/alice/dash/README.md")
        model.selection = api
        let renamed = SidebarItem.session(alias: "acme-devmachine", name: "dashboard")
        model.moveTabs(from: dash, to: renamed)
        XCTAssertEqual(model.openTabs.items, [
            .session(renamed), .file(owner: renamed, path: "/home/alice/dash/README.md"), .session(api),
        ])
        XCTAssertEqual(model.title(for: .file(owner: renamed, path: "/home/alice/dash/README.md")), "README.md")
    }

    func testAFileTabReopensItsSessionAndTheFile() throws {
        let model = model()
        let viewer = try XCTUnwrap(viewer)
        model.selection = dash
        viewer.open(.remote(alias: "acme-devmachine", session: "dash"), path: "/home/alice/dash/README.md")
        let fileTab = CenterTab.file(owner: dash, path: "/home/alice/dash/README.md")
        XCTAssertEqual(model.openTabs.items, [.session(dash), fileTab])
        XCTAssertTrue(model.isSelected(tab: fileTab))
        XCTAssertFalse(model.isSelected(tab: .session(dash)), "the file is on screen, not the terminal")

        model.select(tab: .session(dash))
        XCTAssertFalse(viewer.isOpen, "the session tab puts the terminal back")
        XCTAssertTrue(model.isSelected(tab: .session(dash)))
        XCTAssertFalse(model.isSelected(tab: fileTab))
        XCTAssertEqual(model.openTabs.items, [.session(dash), fileTab], "the file tab stays")

        model.select(tab: fileTab)
        XCTAssertTrue(viewer.isOpen)
        viewer.close()
        model.selection = api
        XCTAssertFalse(model.isSelected(tab: fileTab))
        XCTAssertEqual(model.openTabs.items, [.session(dash), fileTab, .session(api)], "the viewer's × keeps the tab")

        model.select(tab: fileTab)
        XCTAssertEqual(model.selection, dash)
        XCTAssertTrue(viewer.isOpen)
        XCTAssertEqual(viewer.path, "/home/alice/dash/README.md")
        XCTAssertEqual(model.openTabs.items, [.session(dash), fileTab, .session(api)])
    }

    func testClosingAFileTabClosesTheViewerOnlyWhenItShowsThatFile() throws {
        let model = model()
        let viewer = try XCTUnwrap(viewer)
        model.selection = dash
        viewer.open(.remote(alias: "acme-devmachine", session: "dash"), path: "/home/alice/dash/a.md")
        viewer.open(.remote(alias: "acme-devmachine", session: "dash"), path: "/home/alice/dash/b.md")
        model.close(tab: .file(owner: dash, path: "/home/alice/dash/a.md"))
        XCTAssertTrue(viewer.isOpen)
        XCTAssertEqual(model.openTabs.items, [.session(dash), .file(owner: dash, path: "/home/alice/dash/b.md")])
        model.close(tab: .file(owner: dash, path: "/home/alice/dash/b.md"))
        XCTAssertFalse(viewer.isOpen)
        XCTAssertEqual(model.openTabs.items, [.session(dash)])
        XCTAssertEqual(model.selection, dash)
    }

    func testAnotherSessionFromTheSidebarPutsTheFileAway() throws {
        let model = model()
        let viewer = try XCTUnwrap(viewer)
        model.selection = dash
        viewer.open(.remote(alias: "acme-devmachine", session: "dash"), path: "/home/alice/dash/a.md")
        let fileTab = CenterTab.file(owner: dash, path: "/home/alice/dash/a.md")

        model.selection = api
        XCTAssertFalse(viewer.isOpen, "dash's file never covers api's terminal")
        XCTAssertTrue(model.isSelected(tab: .session(api)))
        XCTAssertTrue(model.openTabs.contains(fileTab), "the tab waits for dash")

        model.selection = dash
        XCTAssertFalse(viewer.isOpen)
        XCTAssertTrue(model.isSelected(tab: .session(dash)))

        model.select(tab: fileTab)
        XCTAssertTrue(viewer.isOpen)
        model.goHome()
        XCTAssertFalse(viewer.isOpen, "Home puts the file away too")
    }

    func testClosingTheFileOnScreenShowsItsNeighbourTab() throws {
        let model = model()
        let viewer = try XCTUnwrap(viewer)
        let target = CommandTarget.remote(alias: "acme-devmachine", session: "dash")
        model.selection = dash
        viewer.open(target, path: "/home/alice/dash/a.md")
        viewer.open(target, path: "/home/alice/dash/b.md")
        model.select(tab: .file(owner: dash, path: "/home/alice/dash/a.md"))
        XCTAssertEqual(viewer.path, "/home/alice/dash/a.md")

        model.close(tab: .file(owner: dash, path: "/home/alice/dash/a.md"))
        XCTAssertEqual(viewer.path, "/home/alice/dash/b.md", "the tab to the right, as a browser does")
        XCTAssertEqual(model.openTabs.items, [.session(dash), .file(owner: dash, path: "/home/alice/dash/b.md")])

        model.close(tab: .file(owner: dash, path: "/home/alice/dash/b.md"))
        XCTAssertFalse(viewer.isOpen, "nothing to the right: the session tab to the left")
        XCTAssertEqual(model.selection, dash)
        XCTAssertTrue(model.isSelected(tab: .session(dash)))
    }

    func testClosingTheSelectedSessionTabGoesToTheNeighbourOrHome() {
        let model = model()
        model.selection = dash
        model.fileOpened(path: "/home/alice/dash/a.md")
        model.selection = shell
        model.selection = api
        model.close(tab: .session(shell))
        XCTAssertEqual(model.selection, api, "closing another tab keeps the selection")
        model.close(tab: .session(api))
        XCTAssertEqual(model.selection, dash, "the left neighbour, since nothing is to the right")
        XCTAssertEqual(model.openTabs.items, [.session(dash), .file(owner: dash, path: "/home/alice/dash/a.md")])
        model.close(tab: .session(dash))
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.openTabs.items, [], "a session's file tabs go with it")
    }

    func testTheStripShowsTheTabsOfTheWorkspaceOnScreenAndNoneOnHome() {
        let model = model()
        let beta = SidebarItem.session(alias: "beta-devmachine", name: "web")
        model.selection = dash
        model.fileOpened(path: "/home/alice/dash/a.md")
        model.selection = shell
        model.selection = beta
        model.selection = api
        XCTAssertEqual(model.visibleTabs, [.session(dash), .file(owner: dash, path: "/home/alice/dash/a.md"), .session(api)])
        model.selection = shell
        XCTAssertEqual(model.visibleTabs, [.session(shell)])
        model.selection = beta
        XCTAssertEqual(model.visibleTabs, [.session(beta)])
        model.goHome()
        XCTAssertEqual(model.visibleTabs, [])
        XCTAssertEqual(model.openTabs.items.count, 5, "Home hides the tabs; it does not close them")
    }

    func testClosingTheSelectedSessionTabStaysInItsWorkspace() {
        let model = model()
        model.selection = dash
        model.selection = shell
        model.selection = api
        model.close(tab: .session(api))
        XCTAssertEqual(model.selection, dash, "the neighbour in the same workspace, not the local shell between them")
        model.close(tab: .session(dash))
        XCTAssertNil(model.selection, "no tab left in the workspace goes Home, not to another workspace")
        XCTAssertEqual(model.openTabs.items, [.session(shell)])
    }

    func testCommandWClosesTheTabOnScreenAndKeepsTheSession() throws {
        let model = model()
        let viewer = try XCTUnwrap(viewer)
        model.sessionsByAlias["acme-devmachine"] = [TmuxSession(name: "dash", windows: 1, harnesses: [])]
        model.selection = api
        model.selection = dash
        viewer.open(.remote(alias: "acme-devmachine", session: "dash"), path: "/home/alice/dash/a.md")
        let fileTab = CenterTab.file(owner: dash, path: "/home/alice/dash/a.md")
        XCTAssertEqual(model.tabOnScreen, fileTab, "the file the viewer shows goes first")

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeTab)
        XCTAssertFalse(viewer.isOpen)
        XCTAssertEqual(model.openTabs.items, [.session(api), .session(dash)])
        XCTAssertEqual(model.selection, dash)
        XCTAssertEqual(model.tabOnScreen, .session(dash))

        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeTab)
        XCTAssertEqual(model.openTabs.items, [.session(api)])
        XCTAssertEqual(model.selection, api)
        XCTAssertNil(model.pendingEndSession)
        XCTAssertEqual(model.sessions(in: "acme-devmachine").map(\.name), ["dash"], "the session keeps running")

        model.goHome()
        XCTAssertNil(model.tabOnScreen)
        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeWindow)

        model.selection = api
        model.dropTabs(of: api)
        XCTAssertNil(model.tabOnScreen, "a session on screen without a tab leaves ⌘W to the window")
        XCTAssertEqual(model.handleCloseCommand(inMainWindow: true), .closeWindow)
        XCTAssertEqual(model.selection, api)
    }

    func testClosingASessionTabKeepsItsTerminalInTheSidebar() {
        let model = model()
        model.sessionsByAlias["acme-devmachine"] = [TmuxSession(name: "dash", windows: 1, harnesses: [])]
        model.selection = dash
        model.close(tab: .session(dash))
        XCTAssertEqual(model.sessions(in: "acme-devmachine").map(\.name), ["dash"])
    }
}
