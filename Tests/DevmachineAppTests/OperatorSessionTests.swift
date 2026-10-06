import XCTest
import DevmachineCore
@testable import DevmachineApp

private final class ZmxRunner: CommandRunner, @unchecked Sendable {
    private let listing: String

    init(listing: String = "") {
        self.listing = listing
    }

    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        executable == "/fixtures/zmx" ? listing : ""
    }
}

private final class RecordingSender: SessionCommandSending, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(command: String, target: CommandTarget)] = []

    func send(_ command: String, into target: CommandTarget) throws {
        lock.lock()
        values.append((command, target))
        lock.unlock()
    }

    var sent: [(command: String, target: CommandTarget)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
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

@MainActor
final class OperatorSessionTests: XCTestCase {
    private let operatorPath = "/Users/alice/.config/devmachine"
    private let operatorListing = "name=Operator\tpid=100\tclients=1\tcwd=/Users/alice/.config/devmachine"

    private func facade(_ installed: Set<String>) -> HarnessSettingsFacade {
        HarnessSettingsFacade(registry: .builtIn, locator: DemoExecutableLocator(installed: installed))
    }

    private func settings(operatorProgram: SessionLaunchChoice? = nil, enabled: Bool = true) -> AppSettings {
        AppSettings(
            opsRepoPath: operatorPath, hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", operatorProgram: operatorProgram, operatorSessionEnabled: enabled)
    }

    private func settingsStore(_ value: AppSettings) -> SettingsStore {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "app.devmachine.mac.tests.\(UUID().uuidString)")!)
        store.settings = value
        return store
    }

    private func model(
        installed: Set<String>, listing: String = "", sender: RecordingSender = RecordingSender()
    ) -> AppModel {
        AppModel(
            store: SessionStore(runner: ZmxRunner()),
            harnessSettingsFacade: facade(installed),
            localRunner: ZmxRunner(listing: listing),
            sessionCommandSender: sender,
            zmxPath: "/fixtures/zmx")
    }

    private var operatorItem: SidebarItem {
        .localSession(name: Workspace.operatorSession, path: operatorPath)
    }

    // MARK: Detection

    func testTheInstalledHarnessesAreEveryCLIOnThisMacInRegistryOrder() {
        let facade = facade(["pi", "claude", "kimi"])
        XCTAssertEqual(facade.installedHarnesses.map(\.id), [.claude, .pi, .kimi])
        XCTAssertEqual(facade.operatorLaunchOptions.map(\.id), ["terminal", "claude", "pi", "kimi"])
    }

    func testTheChooserHasACardPerHarnessThenTerminalOnly() {
        let options = OperatorChooserPage.options(for: [.claude, .codex, .pi], facade: facade(["claude", "codex", "pi"]))
        XCTAssertEqual(options.map(OperatorChooserPage.title(for:)), ["Claude Code", "OpenAI Codex", "Pi", "Terminal only"])
        XCTAssertEqual(options.last?.choice, .terminal)
    }

    func testACardSaysWhetherTheHarnessStartsWithTheQuestion() {
        XCTAssertEqual(
            OperatorChooserPage.detail(for: .harness(.claude), firstPick: true),
            "Starts by asking: \u{201C}Explain to me what I can do here.\u{201D}")
        XCTAssertFalse(OperatorChooserPage.detail(for: .harness(.pi), firstPick: true).contains("Starts by asking"))
    }

    func testAfterTheFirstPickNoCardPromisesTheQuestion() {
        XCTAssertFalse(OperatorChooserPage.detail(for: .harness(.claude), firstPick: false).contains("Starts by asking"))
    }

    func testAChosenHarnessWhoseCLIIsGoneStartsAPlainShell() {
        XCTAssertEqual(facade(["claude"]).operatorProgram(for: settings(operatorProgram: .harness(.codex))), .terminal)
        XCTAssertEqual(
            facade(["claude"]).operatorProgram(for: settings(operatorProgram: .harness(.claude))), .harness(.claude))
        XCTAssertNil(facade(["claude"]).operatorProgram(for: settings()))
    }

    // MARK: Startup command

    func testTheFirstMessageIsAnArgumentForClaudeAndCodexOnly() {
        XCTAssertEqual(
            SessionStartup.asking(HarnessPrompt.operatorIntro, with: .harness(.claude), command: "claude"),
            .command("claude 'Explain to me what I can do here.'"))
        XCTAssertEqual(
            SessionStartup.asking(HarnessPrompt.operatorIntro, with: .harness(.codex), command: "codex"),
            .command("codex 'Explain to me what I can do here.'"))
        XCTAssertEqual(
            SessionStartup.asking(HarnessPrompt.operatorIntro, with: .harness(.pi), command: "pi"),
            .program(.harness(.pi)))
        XCTAssertEqual(SessionStartup.asking("hi", with: .terminal, command: nil), .program(.terminal))
        XCTAssertEqual(
            SessionStartup.asking("it's", with: .harness(.claude), command: "claude"),
            .command(#"claude 'it'\''s'"#))
    }

    // MARK: First open

    func testTheFirstOpenShowsTheChooserInsteadOfTheTerminal() async throws {
        let model = model(installed: ["claude", "codex"])
        model.settings = settings()

        model.clickLocalSession(operatorItem)

        try await waitUntil { model.activePage != nil }
        XCTAssertEqual(model.activePage, .operatorChooser([.claude, .codex], last: nil))
        XCTAssertNil(model.selection)
    }

    // MARK: Later opens

    func testReopeningAfterTheSessionEndedAsksAgainWithTheLastPickSelected() async throws {
        let sender = RecordingSender()
        let model = model(installed: ["claude", "pi"], sender: sender)
        model.settings = settings(operatorProgram: .harness(.pi))

        model.clickLocalSession(operatorItem)

        try await waitUntil { model.activePage != nil }
        XCTAssertEqual(model.activePage, .operatorChooser([.claude, .pi], last: .harness(.pi)))
        XCTAssertNil(model.selection)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testALaterPickStartsTheHarnessWithoutTheQuestion() async throws {
        let sender = RecordingSender()
        let model = model(installed: ["claude", "pi"], listing: operatorListing, sender: sender)
        let store = settingsStore(settings(operatorProgram: .harness(.pi)))
        model.settings = store.settings

        model.chooseOperatorProgram(.harness(.claude), in: store)

        XCTAssertEqual(store.settings?.operatorProgram, .harness(.claude))
        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "claude")
    }

    func testPickingAHarnessRemembersItAndStartsItWithTheQuestion() async throws {
        let sender = RecordingSender()
        let model = model(installed: ["claude", "codex"], listing: operatorListing, sender: sender)
        let store = settingsStore(settings())
        model.settings = store.settings

        model.chooseOperatorProgram(.harness(.codex), in: store)

        XCTAssertEqual(store.settings?.operatorProgram, .harness(.codex))
        XCTAssertEqual(model.settings?.operatorProgram, .harness(.codex))
        XCTAssertEqual(model.selection, operatorItem)
        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "codex 'Explain to me what I can do here.'")
        XCTAssertEqual(sender.sent.first?.target, .local(session: Workspace.operatorSession, path: operatorPath))
    }

    func testTerminalOnlyIsRememberedAndTypesNothing() async throws {
        let sender = RecordingSender()
        let model = model(installed: ["claude"], listing: operatorListing, sender: sender)
        let store = settingsStore(settings())
        model.settings = store.settings

        model.chooseOperatorProgram(.terminal, in: store)

        XCTAssertEqual(store.settings?.operatorProgram, .terminal)
        XCTAssertEqual(model.selection, operatorItem)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testWithNoHarnessInstalledItOpensTheTerminalAndKeepsAskingForLater() async throws {
        let model = model(installed: [])
        model.settings = settings()

        model.clickLocalSession(operatorItem)

        try await waitUntil { model.selection != nil }
        XCTAssertEqual(model.selection, operatorItem)
        XCTAssertNil(model.activePage)
        XCTAssertNil(model.settings?.operatorProgram)
    }

    func testARunningOperatorIsShownWithoutTheChooser() async throws {
        let sender = RecordingSender()
        let model = model(installed: ["claude"], listing: operatorListing, sender: sender)
        model.settings = settings()

        model.jump(to: operatorItem)

        try await waitUntil { model.selection != nil }
        XCTAssertEqual(model.selection, operatorItem)
        XCTAssertNil(model.activePage)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testTheOperatorWalkCapturesTheChooserAndBothSettings() {
        XCTAssertEqual(
            DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "operator"]).map(\.fileName),
            ["200-operator-chooser.png", "201-operator-general.png", "202-operator-general-off.png",
             "203-operator-harnesses.png", "204-operator-chooser-again.png"])
    }

    // MARK: Enable switch

    func testTurningTheOperatorOffHidesItFromTheSidebarAndThePalette() {
        let model = model(installed: [])
        model.settings = settings(enabled: false)
        XCTAssertFalse(model.localSessions.contains { $0.handle == Workspace.operatorSession })
        XCTAssertFalse(model.paletteItems().contains { $0.id == "local/\(Workspace.operatorSession)" })

        var context = PaletteContext()
        context.localSessions = model.localSessions
        XCTAssertNil(CommandRegistry.commands(in: context).first { $0.id == "go.operator" })
    }

    func testAHiddenOperatorStaysHiddenWhileItsShellRuns() {
        let model = model(installed: [])
        model.settings = settings(enabled: false)
        model.acceptLocalScanForTesting(
            sessions: [ZmxSession(name: Workspace.operatorSession, pid: 100, clients: 1, directory: operatorPath)],
            harnesses: [:])
        XCTAssertFalse(model.localSessions.contains { $0.handle == Workspace.operatorSession })
    }

    func testTurningItOnAgainBringsItBack() {
        let model = model(installed: [])
        model.settings = settings(enabled: false)
        model.settings?.operatorSessionEnabled = true
        XCTAssertEqual(model.localSessions.first?.handle, Workspace.operatorSession)

        var context = PaletteContext()
        context.localSessions = model.localSessions
        XCTAssertNotNil(CommandRegistry.commands(in: context).first { $0.id == "go.operator" })
    }

    func testSavingItOffLeavesAnOpenOperatorForHome() {
        let model = model(installed: [])
        model.settings = settings()
        model.selection = operatorItem
        model.settings?.operatorSessionEnabled = false

        model.applyOperatorVisibility()

        XCTAssertNil(model.selection)
    }

    func testAHiddenOperatorCannotBeOpened() async throws {
        let model = model(installed: ["claude"])
        model.settings = settings(enabled: false)

        model.clickLocalSession(operatorItem)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(model.selection)
        XCTAssertNil(model.activePage)
    }
}
