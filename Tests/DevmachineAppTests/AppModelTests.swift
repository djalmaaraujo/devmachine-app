import XCTest
import Combine
import DevmachineCore
@testable import DevmachineApp

private final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private(set) var calls = 0

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return outputs.count > 1 ? outputs.removeFirst() : (outputs.first ?? "")
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class CountingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callsByAlias: [String: Int] = [:]

    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        guard let alias = args.first else { return "" }
        lock.lock()
        callsByAlias[alias, default: 0] += 1
        lock.unlock()
        return "dash|1\n@@PANES@@\ndash|claude"
    }

    func calls(for alias: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callsByAlias[alias] ?? 0
    }
}

private struct CodexOnThisMac: ExecutableLocating {
    func executable(named name: String) -> URL? {
        name == "codex" ? URL(fileURLWithPath: "/opt/homebrew/bin/codex") : nil
    }
}

private let codexFacade = HarnessSettingsFacade(registry: .builtIn, locator: CodexOnThisMac())

private final class HarnessProcessRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let zmxListing: String
    private let processListing: String
    private let remoteListing: String
    private var calls: [(executable: String, args: [String])] = []

    init(zmxListing: String = "", processListing: String = "", remoteListing: String = "") {
        self.zmxListing = zmxListing
        self.processListing = processListing
        self.remoteListing = remoteListing
    }

    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        lock.lock()
        calls.append((executable, args))
        lock.unlock()
        switch executable {
        case "/fixtures/zmx": return zmxListing
        case "/bin/ps": return processListing
        case "/usr/bin/ssh": return remoteListing
        default: return ""
        }
    }

    func callCount(for executable: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.filter { $0.executable == executable }.count
    }

    var recordedCalls: [(executable: String, args: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class RecordingSessionCommandSender: SessionCommandSending, @unchecked Sendable {
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
final class AppModelTests: XCTestCase {
    func testWorkspaceAndSessionLoadingUsesDomainSources() async throws {
        let workspace = Workspace(name: "acme", alias: "acme-devmachine")
        let session = TmuxSession(name: "dash", windows: 2, harnesses: [.claude, .codex])
        let model = AppModel(services: fixtureServices(
            workspaces: [workspace], sessions: [session],
            local: LocalSessionSnapshot(
                sessions: [ZmxSession(name: "beta", pid: 42, clients: 1, directory: "/Users/alice/dev/beta")],
                harnesses: ["beta": [.codex]])))
        model.settings = .empty

        model.loadWorkspaces()
        try await waitUntil { model.sessionsByAlias[workspace.alias] != nil && !model.liveLocalSessions.isEmpty }

        XCTAssertEqual(model.workspaces, [workspace])
        XCTAssertEqual(model.sessionsByAlias[workspace.alias], [session])
        XCTAssertEqual(model.localSessionHarnesses["beta"], [.codex])
        XCTAssertEqual(model.badges(for: session).map(\.id), [.claude, .codex])
    }

    func testEverySelectedSessionCanShowThePanelWithoutAContextProvider() {
        let model = AppModel(services: fixtureServices())
        model.contextCollapsed = false
        model.contextTab = .files
        for harnesses: Set<HarnessID> in [[.claude], [.codex], []] {
            model.sessionsByAlias["acme-devmachine"] = [
                TmuxSession(name: "dash", windows: 1, harnesses: harnesses)]
            model.selection = .session(alias: "acme-devmachine", name: "dash")
            XCTAssertTrue(model.showsContextPanel)
            XCTAssertEqual(model.selectedSessionTarget, .remote(alias: "acme-devmachine", session: "dash"))
            XCTAssertFalse(model.context.isPolling)
            model.selection = .localSession(name: "beta", path: "/Users/alice/dev/beta")
            XCTAssertTrue(model.showsContextPanel)
            XCTAssertEqual(model.selectedSessionTarget, .local(session: "beta", path: "/Users/alice/dev/beta"))
        }
        model.selection = nil
        XCTAssertFalse(model.showsContextPanel)
    }

    func testContextPollingStopsWhenPanelIsHiddenOrHasNoProvider() {
        let model = AppModel(services: fixtureServices())
        model.contextCollapsed = false
        model.contextTab = .context
        model.sessionsByAlias["acme-devmachine"] = [
            TmuxSession(name: "dash", windows: 1, harnesses: [.claude])]
        model.selection = .session(alias: "acme-devmachine", name: "dash")
        XCTAssertTrue(model.context.isPolling)
        model.contextCollapsed = true
        XCTAssertFalse(model.context.isPolling)
        model.contextCollapsed = false
        XCTAssertTrue(model.context.isPolling)
        model.activePage = .stack([])
        XCTAssertFalse(model.context.isPolling)
        model.activePage = nil
        XCTAssertTrue(model.context.isPolling)
        for harnesses: Set<HarnessID> in [[HarnessID(rawValue: "aider")], []] {
            model.sessionsByAlias["acme-devmachine"] = [
                TmuxSession(name: "dash", windows: 1, harnesses: harnesses)]
            model.syncContext()
            XCTAssertFalse(model.context.isPolling)
            XCTAssertNil(model.context.state)
            XCTAssertTrue(model.showsContextPanel)
        }
    }

    func testRemoteRefreshDetectsEveryHarnessWhetherOrNotItIsEnabled() async throws {
        let runner = HarnessProcessRunner(remoteListing: """
        dash|1
        @@PANES@@
        dash|claude
        dash|codex
        """)
        let model = AppModel(store: SessionStore(runner: runner))
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.codex])
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]

        model.refresh(alias: "acme-devmachine")

        try await waitUntil { model.sessionsByAlias["acme-devmachine"] != nil }
        XCTAssertEqual(model.sessionsByAlias["acme-devmachine"]?.first?.harnesses, [.claude, .codex])
        XCTAssertEqual(runner.callCount(for: "/usr/bin/ssh"), 1)
    }

    func testARemoteOpencodeSessionIsBadgedWithOnlyClaudeEnabled() async throws {
        let runner = HarnessProcessRunner(remoteListing: """
        dash|1
        @@PANES@@
        dash|opencode
        """)
        let model = AppModel(store: SessionStore(runner: runner))
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.claude])
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]

        model.refresh(alias: "acme-devmachine")

        try await waitUntil { model.sessionsByAlias["acme-devmachine"] != nil }
        let session = try XCTUnwrap(model.sessionsByAlias["acme-devmachine"]?.first)
        XCTAssertEqual(session.harnesses, [.opencode])
        XCTAssertEqual(model.badges(for: session).map(\.id), [.opencode])
    }

    func testALocalOpencodeSessionIsBadgedWithOnlyClaudeEnabled() async throws {
        let runner = HarnessProcessRunner(
            zmxListing: "name=acme\tpid=100\tclients=1\tcwd=/Users/alice/dev/acme",
            processListing: """
             100 1 -zsh
             200 100 node
             300 200 /Users/alice/.opencode/bin/opencode
            """)
        let model = AppModel(
            store: SessionStore(runner: HarnessProcessRunner()),
            localRunner: runner,
            sessionCommandSender: RecordingSessionCommandSender(),
            zmxPath: "/fixtures/zmx")
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.claude])

        model.scanLocalSessions()

        try await waitUntil { model.localSessionHarnesses["acme"] != nil }
        XCTAssertEqual(model.localSessionHarnesses["acme"], [.opencode])
    }

    func testLocalScanUsesOneProcessSnapshotForAllHarnessesAndSessions() async throws {
        let runner = HarnessProcessRunner(
            zmxListing: """
            name=acme\tpid=100\tclients=1\tcwd=/Users/alice/dev/acme
            name=beta\tpid=400\tclients=1\tcwd=/Users/alice/dev/beta
            """,
            processListing: """
             100 1 -zsh
             200 100 claude
             300 100 codex
             400 1 -zsh
             500 400 aider
            """)
        let model = AppModel(
            store: SessionStore(runner: HarnessProcessRunner()),
            localRunner: runner,
            sessionCommandSender: RecordingSessionCommandSender(),
            zmxPath: "/fixtures/zmx")
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.claude, .codex])

        model.scanLocalSessions()

        try await waitUntil { model.localSessionHarnesses.keys.count == 2 }
        XCTAssertEqual(model.localSessionHarnesses["acme"], [.claude, .codex])
        XCTAssertEqual(model.localSessionHarnesses["beta"], [])
        XCTAssertEqual(runner.callCount(for: "/bin/ps"), 1)
    }

    func testBadgesFollowRegistryOrderInsteadOfSetOrder() {
        let facade = SessionHarnessFacade(registry: .builtIn)

        let badges = facade.badges(for: [.codex, .claude])

        XCTAssertEqual(badges.map(\.id), [.claude, .codex])
        XCTAssertEqual(badges.map(\.helpText), [
            "Claude Code is running in this session",
            "OpenAI Codex is running in this session"
        ])
    }

    func testPaletteItemsCarryOrderedHarnessBadgePresentations() throws {
        let model = AppModel(store: SessionStore(runner: CountingRunner()))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.sessionsByAlias = [
            "acme-devmachine": [
                TmuxSession(name: "dash", windows: 1, harnesses: [.codex, .claude])
            ]
        ]

        let item = try XCTUnwrap(model.paletteItems().first { $0.id == "acme-devmachine/dash" })

        XCTAssertEqual(item.badges.map(\.shortTitle), ["Claude", "Codex"])
        XCTAssertEqual(item.badges.map(\.helpText), [
            "Claude Code is running in this session",
            "OpenAI Codex is running in this session"
        ])
    }

    func testLocalPaletteItemsCarryDetectedHarnessBadges() throws {
        let model = AppModel(store: SessionStore(runner: CountingRunner()))
        model.acceptLocalScanForTesting(
            sessions: [
                ZmxSession(name: Workspace.operatorSession, pid: 4242, clients: 1, directory: "/tmp")
            ],
            harnesses: [Workspace.operatorSession: [.codex]])

        let item = try XCTUnwrap(model.paletteItems().first { $0.id == "local/Operator" })

        XCTAssertEqual(item.badges.map(\.shortTitle), ["Codex"])
        XCTAssertEqual(item.badges.map(\.helpText), ["OpenAI Codex is running in this session"])
    }

    func testHarnessSessionCountIncludesRemoteAndLocalSessionsWithoutDoubleCounting() {
        let model = AppModel(store: SessionStore(runner: CountingRunner()))
        model.sessionsByAlias = [
            "acme-devmachine": [
                TmuxSession(name: "dash", windows: 1, harnesses: [.claude, .codex]),
                TmuxSession(name: "plain", windows: 1, harnesses: [])
            ],
            "beta-devmachine": [
                TmuxSession(name: "web", windows: 1, harnesses: [.codex])
            ]
        ]
        model.acceptLocalScanForTesting(
            sessions: [
                ZmxSession(name: Workspace.operatorSession, pid: 4242, clients: 1, directory: "/tmp")
            ],
            harnesses: [Workspace.operatorSession: [.claude]])

        XCTAssertEqual(model.sessionCount, 3 + model.localSessions.count)
        XCTAssertEqual(model.harnessSessionCount, 3)
    }

    func testStartingALocalSessionUsesTheLocalHarnessDefault() async throws {
        let runner = HarnessProcessRunner(
            zmxListing: "name=acme\tpid=100\tclients=1\tcwd=/Users/alice/dev/acme")
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: HarnessProcessRunner()),
            harnessSettingsFacade: codexFacade,
            localRunner: runner,
            sessionCommandSender: sender,
            zmxPath: "/fixtures/zmx")
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.claude, .codex],
            localSessionProgram: .harness(.codex))

        model.startProgram(in: .local(session: "acme", path: "/Users/alice/dev/acme"))

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "codex")
        XCTAssertEqual(
            sender.sent.first?.target,
            .local(session: "acme", path: "/Users/alice/dev/acme"))
    }

    func testALocalDefaultWhoseCLIIsNotOnThisMacStartsAPlainShell() async throws {
        let runner = HarnessProcessRunner(
            zmxListing: "name=acme\tpid=100\tclients=1\tcwd=/Users/alice/dev/acme")
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: HarnessProcessRunner()),
            harnessSettingsFacade: codexFacade,
            localRunner: runner,
            sessionCommandSender: sender,
            zmxPath: "/fixtures/zmx")
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.claude, .opencode],
            localSessionProgram: .harness(.opencode), remoteSessionProgram: .harness(.opencode))

        model.startProgram(in: .local(session: "acme", path: "/Users/alice/dev/acme"))
        model.startProgram(in: .remote(alias: "acme-devmachine", session: "dash"))

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.map(\.command), ["opencode"])
        XCTAssertEqual(sender.sent.first?.target, .remote(alias: "acme-devmachine", session: "dash"))
    }

    func testNewRemoteSessionUsesItsWorkspaceHarnessOverrideWithoutAProbe() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: runner),
            sessionCommandSender: sender)
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.claude, .codex],
            remoteSessionProgram: .harness(.claude),
            workspaceSessionPrograms: ["acme-devmachine": .harness(.codex)])

        model.confirmNewSession(alias: "acme-devmachine", name: "dash", directory: "~/dev/acme")

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "codex")
        XCTAssertEqual(
            sender.sent.first?.target,
            .remote(alias: "acme-devmachine", session: "dash"))
        XCTAssertEqual(runner.callCount(for: "/usr/bin/ssh"), 1)
        XCTAssertTrue(runner.recordedCalls[0].args.last?.contains("tmux new-session -d") == true)
    }

    func testNewRemoteSessionUsesTheRemoteHarnessFallback() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: runner),
            sessionCommandSender: sender)
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.claude, .codex],
            remoteSessionProgram: .harness(.claude))

        model.confirmNewSession(alias: "beta-devmachine", name: "web", directory: "~/dev/beta")

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "claude")
        XCTAssertEqual(runner.callCount(for: "/usr/bin/ssh"), 1)
    }

    func testQuickNewSessionFromHomeOpensTheDestinationChooser() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))

        model.requestQuickSession()

        XCTAssertTrue(model.showNewSessionChooser)
    }

    func testQuickNewSessionFromAPageUsesTheChooserInsteadOfTheHiddenSelection() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.selection = .session(alias: "acme-devmachine", name: "web")
        model.activePage = .stats

        model.requestQuickSession()

        XCTAssertTrue(model.showNewSessionChooser)
    }

    func testQuickNewSessionFromAStackUsesTheFocusedPane() async throws {
        let runner = HarnessProcessRunner(remoteListing: "/srv/focused\n")
        let model = AppModel(
            store: SessionStore(runner: runner), sessionSuffix: { "f1" })
        let first = SessionRef(alias: "acme-devmachine", name: "first")
        let focused = SessionRef(alias: "acme-devmachine", name: "focused")
        model.stackSessions([first, focused])

        model.requestQuickSession(focusedRef: focused)

        try await waitUntil { runner.callCount(for: "/usr/bin/ssh") >= 2 }
        let commands = runner.recordedCalls.compactMap { $0.args.last }
        XCTAssertTrue(commands.first?.contains("-t 'focused'") == true)
        XCTAssertEqual(
            model.selection,
            .session(alias: "acme-devmachine", name: "focused-f1"))
    }

    func testQuickLocalSessionUsesTheLiveDirectoryAndLocalHarnessDefault() async throws {
        let runner = HarnessProcessRunner(
            zmxListing: "name=project-q7\tpid=100\tclients=1\tcwd=/Users/alice/dev/project")
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: runner), harnessSettingsFacade: codexFacade, localRunner: runner,
            sessionCommandSender: sender, zmxPath: "/fixtures/zmx",
            sessionSuffix: { "q7" })
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.codex],
            localSessionProgram: .harness(.codex))
        model.addLocalSession(path: "/Users/alice/dev/base")
        model.acceptLocalScanForTesting(
            sessions: [ZmxSession(
                name: "base", pid: 42, clients: 1, directory: "/Users/alice/dev/project")],
            harnesses: [:])

        model.requestQuickSession()

        XCTAssertEqual(
            model.selection,
            .localSession(name: "project-q7", path: "/Users/alice/dev/project"))
        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "codex")
        XCTAssertEqual(
            sender.sent.first?.target,
            .local(session: "project-q7", path: "/Users/alice/dev/project"))
        model.removeLocalSession(handle: "base")
        model.removeLocalSession(handle: "project-q7")
    }

    func testQuickRemoteSessionReadsCurrentDirectoryAndUsesWorkspaceHarness() async throws {
        let runner = HarnessProcessRunner(remoteListing: "/home/alice/dev/project\n")
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: runner), sessionCommandSender: sender,
            sessionSuffix: { "q7" })
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", enabledHarnesses: [.claude, .codex],
            remoteSessionProgram: .harness(.claude),
            workspaceSessionPrograms: ["acme-devmachine": .harness(.codex)])
        model.sessionsByAlias["acme-devmachine"] = [
            TmuxSession(name: "web", windows: 1, harnesses: [])
        ]
        model.selection = .session(alias: "acme-devmachine", name: "web")

        model.requestQuickSession()

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "codex")
        XCTAssertEqual(
            sender.sent.first?.target,
            .remote(alias: "acme-devmachine", session: "project-q7"))
        let remoteCommands = runner.recordedCalls
            .filter { $0.executable == "/usr/bin/ssh" }
            .compactMap { $0.args.last }
        XCTAssertTrue(remoteCommands.first?.contains("#{pane_current_path}") == true)
        XCTAssertTrue(remoteCommands.contains {
            $0.contains("tmux new-session -d") && $0.contains("/home/alice/dev/project")
        })
    }

    func testChooserCreatesLocalSessionWithAutomaticName() {
        let model = AppModel(
            store: SessionStore(runner: BlockingRunner(output: "")),
            sessionSuffix: { "a1" })
        model.showNewSessionChooser = true

        model.createQuickSession(
            destinationAlias: Workspace.local.alias,
            directory: "/Users/alice/dev/project")

        XCTAssertFalse(model.showNewSessionChooser)
        XCTAssertEqual(
            model.selection,
            .localSession(name: "project-a1", path: "/Users/alice/dev/project"))
        model.removeLocalSession(handle: "project-a1")
    }

    func testRefreshAllCallsEachAliasOnce() async throws {
        let runner = CountingRunner()
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine")
        ]

        model.refreshAll()

        try await waitUntil { runner.calls(for: "acme-devmachine") == 1 && runner.calls(for: "beta-devmachine") == 1 }

        XCTAssertEqual(runner.calls(for: "acme-devmachine"), 1)
        XCTAssertEqual(runner.calls(for: "beta-devmachine"), 1)
    }

    func testSelectingASessionPollsOnlyTheSelectedAlias() {
        let runner = CountingRunner()
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine")
        ]
        model.sessionsByAlias = [
            "acme-devmachine": [TmuxSession(name: "dash", windows: 1, harnesses: [.claude])]
        ]

        model.clickSession(SessionRef(alias: "acme-devmachine", name: "dash"))

        XCTAssertTrue(model.hasSelectionPollTimer)
        XCTAssertEqual(model.selectionPollTarget, "acme-devmachine")
    }

    func testChangingSelectionRetargetsThePoll() {
        let runner = CountingRunner()
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine")
        ]
        model.sessionsByAlias = [
            "acme-devmachine": [TmuxSession(name: "dash", windows: 1, harnesses: [.claude])],
            "beta-devmachine": [TmuxSession(name: "web", windows: 1, harnesses: [.claude])]
        ]

        model.clickSession(SessionRef(alias: "acme-devmachine", name: "dash"))
        XCTAssertEqual(model.selectionPollTarget, "acme-devmachine")

        model.clickSession(SessionRef(alias: "beta-devmachine", name: "web"))
        XCTAssertEqual(model.selectionPollTarget, "beta-devmachine")
    }

    func testSelectionStartsThePollAndHomeStopsIt() {
        let runner = CountingRunner()
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.sessionsByAlias = [
            "acme-devmachine": [TmuxSession(name: "dash", windows: 1, harnesses: [.claude])]
        ]

        model.clickSession(SessionRef(alias: "acme-devmachine", name: "dash"))
        XCTAssertTrue(model.hasSelectionPollTimer)
        XCTAssertEqual(model.selectionPollTarget, "acme-devmachine")

        model.goHome()

        XCTAssertFalse(model.hasSelectionPollTimer)
        XCTAssertNil(model.selectionPollTarget)
    }

    func testTheLastPaletteItemIsTheLocalOperatorSession() {
        let model = AppModel(store: SessionStore(runner: CountingRunner()))
        model.settings = AppSettings(
            opsRepoPath: "/Users/alice/dev/ops",
            hostAlias: "myhost",
            publicIP: "203.0.113.10",
            baseDomain: "example.com"
        )

        let last = model.paletteItems().last
        XCTAssertEqual(last?.title, "Operator")
        XCTAssertEqual(last?.subtitle, "Local")
        XCTAssertEqual(last?.target, .localSession(name: "Operator", path: "/Users/alice/dev/ops"))
    }

    func testPollWithSameResultDoesNotRepublish() async throws {
        let runner = ScriptedRunner(outputs: ["dash|1\n@@PANES@@\ndash|claude"])
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]

        model.refresh(alias: "acme-devmachine")
        try await waitUntil { model.sessionsByAlias["acme-devmachine"] != nil }

        let changes = ChangeCounter()
        let token = model.objectWillChange.sink { _ in changes.bump() }
        defer { token.cancel() }

        model.refresh(alias: "acme-devmachine")
        try await waitUntil { runner.callCount == 2 }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(model.sessionsByAlias["acme-devmachine"]?.count, 1)
        XCTAssertEqual(changes.count, 0)
    }

    func testPollWithNewResultRepublishes() async throws {
        let runner = ScriptedRunner(outputs: [
            "dash|1\n@@PANES@@\ndash|claude",
            "dash|1\nweb|2\n@@PANES@@\ndash|claude"
        ])
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]

        model.refresh(alias: "acme-devmachine")
        try await waitUntil { model.sessionsByAlias["acme-devmachine"]?.count == 1 }

        let changes = ChangeCounter()
        let token = model.objectWillChange.sink { _ in changes.bump() }
        defer { token.cancel() }

        model.refresh(alias: "acme-devmachine")
        try await waitUntil { model.sessionsByAlias["acme-devmachine"]?.count == 2 }

        XCTAssertEqual(changes.count, 1)
    }

    func testRefreshSkipsTickWhileTheSameAliasIsInFlight() async throws {
        let runner = BlockingRunner(output: "dash|1\n@@PANES@@\ndash|claude")
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]

        model.refresh(alias: "acme-devmachine")
        try await waitUntil { runner.callCount == 1 }

        model.refresh(alias: "acme-devmachine")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.callCount, 1)

        runner.release()
        try await waitUntil { model.sessionsByAlias["acme-devmachine"] != nil }

        model.refresh(alias: "acme-devmachine")
        runner.release()
        try await waitUntil { runner.callCount == 2 }
    }

    func testRefreshOfAnotherAliasIsNotBlocked() async throws {
        let runner = BlockingRunner(output: "dash|1\n@@PANES@@\ndash|claude")
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine")
        ]

        model.refresh(alias: "acme-devmachine")
        model.refresh(alias: "beta-devmachine")

        try await waitUntil { runner.callCount == 2 }
        runner.release()
        runner.release()
    }

    func testOfflineAliasStaysOfflineWithoutRepublishing() async throws {
        let runner = ThrowingRunner()
        let model = AppModel(store: SessionStore(runner: runner))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]

        model.refresh(alias: "acme-devmachine")
        try await waitUntil { model.offlineAliases.contains("acme-devmachine") }

        let changes = ChangeCounter()
        let token = model.objectWillChange.sink { _ in changes.bump() }
        defer { token.cancel() }

        model.refresh(alias: "acme-devmachine")
        try await waitUntil { runner.callCount == 2 }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(changes.count, 0)
    }

    func testAnotherContextTabStopsTheContextPoll() {
        let model = AppModel(services: fixtureServices())
        model.contextCollapsed = false
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.sessionsByAlias = [
            "acme-devmachine": [TmuxSession(name: "dash", windows: 1, harnesses: [.claude])]
        ]
        model.contextTab = .context
        model.clickSession(SessionRef(alias: "acme-devmachine", name: "dash"))
        XCTAssertTrue(model.context.isPolling)

        model.contextTab = .git
        XCTAssertFalse(model.context.isPolling)

        model.contextTab = .context
        XCTAssertTrue(model.context.isPolling)
        model.context.stop()
    }

    func testOpeningASessionAsksForKeyboardFocus() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.clickSession(SessionRef(alias: "acme-devmachine", name: "dash"))
        let pending = TerminalRegistry.shared.pendingFocusKind
        XCTAssertEqual(pending, .remote(alias: "acme-devmachine", session: "dash"))
    }

    func testStackingAsksForFocusOnTheFirstCell() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.stackSessions([
            SessionRef(alias: "acme-devmachine", name: "dash"),
            SessionRef(alias: "acme-devmachine", name: "api")
        ])
        let pending = TerminalRegistry.shared.pendingFocusKind
        XCTAssertEqual(pending, .remote(alias: "acme-devmachine", session: "dash"))
    }

    func testOpeningALocalSessionClearsTheSessionHighlight() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.clickSession(SessionRef(alias: "acme-devmachine", name: "dash"))
        XCTAssertFalse(model.selectedSessions.isEmpty)

        model.selection = .localSession(name: Workspace.operatorSession, path: "/tmp")
        XCTAssertTrue(model.selectedSessions.isEmpty)
        XCTAssertNil(model.selectionAnchor)
    }

    func testClickingTheOpenLocalSessionGoesHome() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        let item = SidebarItem.localSession(name: "project", path: "/Users/alice/dev/project")

        model.clickLocalSession(item)
        XCTAssertEqual(model.selection, item)

        model.clickLocalSession(item)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.activePage)
    }

    func testGoingHomeClosesTheCurrentPageAndSession() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.selection = .session(alias: "acme-devmachine", name: "dash")
        model.activePage = .stats

        model.goHome()

        XCTAssertNil(model.selection)
        XCTAssertNil(model.activePage)
    }

    func testGoingHomeClearsTheSessionHighlight() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.clickSession(SessionRef(alias: "acme-devmachine", name: "dash"))
        model.selection = nil
        XCTAssertTrue(model.selectedSessions.isEmpty)
    }

    func testNextSessionCrossesWorkspacesAndLocalThenWraps() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.settings = AppSettings(
            opsRepoPath: "/Users/alice/dev/ops", hostAlias: "devmachine",
            publicIP: "203.0.113.10", baseDomain: "example.com")
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine")
        ]
        model.sessionsByAlias = [
            "acme-devmachine": [TmuxSession(name: "dash", windows: 1, harnesses: [])],
            "beta-devmachine": [TmuxSession(name: "web", windows: 1, harnesses: [])]
        ]

        model.moveToNextSession()
        XCTAssertEqual(model.selection, .session(alias: "acme-devmachine", name: "dash"))
        model.moveToNextSession()
        XCTAssertEqual(model.selection, .session(alias: "beta-devmachine", name: "web"))
        model.moveToNextSession()
        XCTAssertEqual(
            model.selection,
            .localSession(name: Workspace.operatorSession, path: "/Users/alice/dev/ops"))
        model.moveToNextSession()
        XCTAssertEqual(model.selection, .session(alias: "acme-devmachine", name: "dash"))
    }

    func testPreviousSessionFromHomeStartsAtTheLastSession() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.settings = AppSettings(
            opsRepoPath: "/Users/alice/dev/ops", hostAlias: "devmachine",
            publicIP: "203.0.113.10", baseDomain: "example.com")
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.sessionsByAlias = [
            "acme-devmachine": [TmuxSession(name: "dash", windows: 1, harnesses: [])]
        ]

        model.moveToPreviousSession()

        XCTAssertEqual(
            model.selection,
            .localSession(name: Workspace.operatorSession, path: "/Users/alice/dev/ops"))
    }

    func testNavigationHistoryIncludesSessionsPagesAndHome() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        let session = SessionRef(alias: "acme-devmachine", name: "dash")
        model.workspaces = [Workspace(name: "acme", alias: session.alias)]
        model.sessionsByAlias[session.alias] = [
            TmuxSession(name: session.name, windows: 1, harnesses: [])
        ]

        model.clickSession(session)
        model.showPage(.stats)
        model.goHome()
        model.goBack()
        XCTAssertEqual(model.activePage, .stats)
        model.goBack()
        XCTAssertEqual(model.selection, .session(alias: session.alias, name: session.name))
        XCTAssertNil(model.activePage)
        model.goForward()
        XCTAssertEqual(model.activePage, .stats)
        model.goForward()
        XCTAssertNil(model.selection)
        XCTAssertNil(model.activePage)
    }

    func testAddAMachineFromSettingsReturnsToSettingsOnMachines() {
        let model = AppModel(services: fixtureServices())
        model.openSettings(.machines)
        model.requestedSettingsSection = nil
        model.showPage(.addMachine)
        XCTAssertEqual(model.activePage, .addMachine)

        model.closeAddMachine()
        XCTAssertEqual(model.activePage, .setup)
        XCTAssertEqual(model.requestedSettingsSection, .machines)
    }

    func testAddAMachineFromAnywhereElseClosesToWhereItWas() {
        let model = AppModel(services: fixtureServices())
        model.showPage(.stats)
        model.showPage(.addMachine)
        model.closeAddMachine()
        XCTAssertNil(model.activePage)
        XCTAssertNil(model.requestedSettingsSection)

        model.openSettings(.machines)
        model.showPage(.addMachine)
        model.showPage(.stats)
        model.showPage(.addMachine)
        model.closeAddMachine()
        XCTAssertNil(model.activePage)
    }

    func testFreshNavigationAfterGoingBackDiscardsForwardHistory() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        let first = SessionRef(alias: "acme-devmachine", name: "first")
        let second = SessionRef(alias: "acme-devmachine", name: "second")
        let replacement = SessionRef(alias: "acme-devmachine", name: "replacement")
        model.workspaces = [Workspace(name: "acme", alias: first.alias)]
        model.sessionsByAlias[first.alias] = [first, second, replacement].map {
            TmuxSession(name: $0.name, windows: 1, harnesses: [])
        }

        model.clickSession(first)
        model.clickSession(second)
        model.goBack()
        model.clickSession(replacement)
        model.goForward()

        XCTAssertEqual(
            model.selection,
            .session(alias: replacement.alias, name: replacement.name))
    }

    func testNavigationHistoryKeepsOnlyTheLastTenDestinations() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.sessionsByAlias["acme-devmachine"] = (1...11).map {
            TmuxSession(name: "session-\($0)", windows: 1, harnesses: [])
        }
        for number in 1...11 {
            model.clickSession(SessionRef(alias: "acme-devmachine", name: "session-\(number)"))
        }

        for _ in 0..<20 { model.goBack() }

        XCTAssertEqual(
            model.selection,
            .session(alias: "acme-devmachine", name: "session-2"))
    }

    @MainActor
    func testLocalIsAlwaysTheLastWorkspace() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine"),
        ]
        XCTAssertEqual(model.sidebarWorkspaces.map(\.name), ["acme", "beta", "Local"])
        XCTAssertTrue(model.sidebarWorkspaces.last?.isLocal == true)
    }

    @MainActor
    func testLocalWorkspaceIsNotPolledOverSSH() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        // `workspaces` is what the ssh sweep walks; Local is added for the
        // sidebar alone and must never reach it.
        XCTAssertFalse(model.workspaces.contains { $0.isLocal })
    }

    @MainActor
    func testLocalAlwaysOffersTheOperatorSession() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        XCTAssertEqual(model.localSessions.map(\.name), ["Operator"])
    }

    @MainActor
    func testAddingAFolderCreatesALocalSessionAndOpensIt() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")

        XCTAssertEqual(model.localSessions.map(\.name), ["Operator", "acme"])
        XCTAssertEqual(
            model.selection, .localSession(name: "acme", path: "/Users/alice/dev/acme"))
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testTheSameFolderTwiceBecomesTwoSessions() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.addLocalSession(path: "/Users/alice/dev/acme")

        XCTAssertEqual(model.localSessions.map(\.name), ["Operator", "acme", "acme 2"])
        model.removeLocalSession(handle: "acme")
        model.removeLocalSession(handle: "acme 2")
    }

    @MainActor
    func testARenamedSessionStillBlocksItsNumberForTheNextOne() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.renameLocalSession(handle: "acme 2", to: "Client work")

        model.addLocalSession(path: "/Users/alice/dev/acme")

        XCTAssertEqual(
            model.localSessions.map(\.handle), ["Operator", "acme", "acme 2", "acme 3"])
        model.removeLocalSession(handle: "acme")
        model.removeLocalSession(handle: "acme 2")
        model.removeLocalSession(handle: "acme 3")
    }

    @MainActor
    func testRemovingALocalSessionDropsItAndClearsTheSelection() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.removeLocalSession(handle: "acme")

        XCTAssertEqual(model.localSessions.map(\.name), ["Operator"])
        XCTAssertNil(model.selection)
    }

    @MainActor
    func testRemovingALocalSessionAsksFirst() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")

        model.askToEndSession(.localSession(name: "acme", path: "/Users/alice/dev/acme"))

        XCTAssertEqual(model.pendingEndSession, SessionEndRequest(
            item: .localSession(name: "acme", path: "/Users/alice/dev/acme"), name: "acme", place: "This Mac"))
        XCTAssertEqual(model.localSessions.map(\.handle), ["Operator", "acme"])

        model.confirmEndSession()

        XCTAssertNil(model.pendingEndSession)
        XCTAssertEqual(model.localSessions.map(\.handle), ["Operator"])
    }

    @MainActor
    func testTheOperatorSessionIsNeverOfferedForRemoval() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.askToEndSession(.localSession(name: Workspace.operatorSession, path: "/Users/alice/dev/ops"))
        XCTAssertNil(model.pendingEndSession)
    }

    @MainActor
    func testTheOperatorSessionCannotBeRemoved() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.removeLocalSession(handle: Workspace.operatorSession)

        XCTAssertEqual(model.localSessions.map(\.name), ["Operator"])
    }

    @MainActor
    func testNothingConnectsBeforeASweepStarts() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        XCTAssertTrue(model.activeTasks.isEmpty)
    }

    @MainActor
    func testTheSweepIsACardLikeEveryOtherJob() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine"),
            Workspace(name: "gamma", alias: "gamma-devmachine"),
        ]
        model.refreshAll()

        XCTAssertEqual(model.activeTasks.count, 1)
        XCTAssertEqual(model.activeTasks.first?.label, "Connecting workspaces\u{2026}")
        XCTAssertEqual(model.activeTasks.first?.total, 3)
        XCTAssertEqual(model.activeTasks.first?.completed, 0)
    }

    @MainActor
    func testATransferShowsABarAndThenClearsIt() async throws {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        let id = model.beginTransfer(label: "Sending image\u{2026}", total: 1000)
        XCTAssertEqual(model.activeTasks.first?.completed, 0)
        XCTAssertEqual(model.activeTasks.first?.total, 1000)
        // Bytes as "400 of 1000" says nothing, so the card shows the bar alone.
        XCTAssertEqual(model.activeTasks.first?.showsCount, false)

        model.advanceTransfer(id, done: 400)
        XCTAssertEqual(model.activeTasks.first?.completed, 400)
        XCTAssertEqual(model.activeTasks.first?.label, "Sending image\u{2026}")

        model.endTransfer(id)
        XCTAssertEqual(model.activeTasks.first?.completed, 1000)
        try await waitUntil { model.activeTasks.isEmpty }
    }

    @MainActor
    func testProgressWithoutATransferIsIgnored() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.advanceTransfer(UUID(), done: 10)
        XCTAssertTrue(model.activeTasks.isEmpty)
    }

    @MainActor
    func testWakingLiftsThePauseAndSweepsAgain() {
        let model = AppModel(store: SessionStore(runner: UnreachableRunner()))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.refreshAll()

        // The sweep marked the workspace offline and paused polling; without a
        // wake the sidebar would stay red for up to two minutes.
        let waitForSweep = expectation(description: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { waitForSweep.fulfill() }
        wait(for: [waitForSweep], timeout: 2)
        XCTAssertTrue(model.isPollingPaused)

        model.resumePollingAfterWake()
        XCTAssertFalse(model.isPollingPaused)
    }


    @MainActor
    func testAFailedLoginOutsideTheSweepPausesPollingTheSameWay() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))

        model.noteSSHFailure(.hostKeyRejected)
        XCTAssertFalse(model.isPollingPaused, "a refused host key tried no login")

        model.noteSSHFailure(.authDenied)
        XCTAssertTrue(model.isPollingPaused)
    }

    @MainActor
    func testALockedAgentIsNotAWorkspaceBeingOffline() {
        let model = AppModel(store: SessionStore(runner: AuthDeniedRunner()))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine"),
        ]
        model.refreshAll()

        let sweep = expectation(description: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sweep.fulfill() }
        wait(for: [sweep], timeout: 2)

        XCTAssertTrue(model.isPollingPaused)
        XCTAssertTrue(model.offlineAliases.isEmpty)
    }

    @MainActor
    func testARefusedHostKeyNeitherPausesPollingNorReadsAsOffline() {
        let model = AppModel(store: SessionStore(runner: HostKeyRejectedRunner()))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine"),
        ]
        model.refreshAll()

        let sweep = expectation(description: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sweep.fulfill() }
        wait(for: [sweep], timeout: 2)

        // No login was tried, so nothing counts toward a ban: the sweep went
        // on to every workspace, and each says why it cannot connect.
        XCTAssertFalse(model.isPollingPaused)
        XCTAssertTrue(model.offlineAliases.isEmpty)
        XCTAssertEqual(model.sessionProblems["acme-devmachine"]?.isHostKeyRejected, true)
        XCTAssertEqual(model.sessionProblems["beta-devmachine"]?.isHostKeyRejected, true)
    }

    @MainActor
    func testTheSidebarSkeletonShowsUntilTheWorkspacesAreRead() async throws {
        let workspace = Workspace(name: "acme", alias: "acme-devmachine")
        let model = AppModel(services: fixtureServices(
            workspaces: [workspace], sessions: [TmuxSession(name: "dash", windows: 1, harnesses: [])]))
        model.settings = .empty
        XCTAssertFalse(model.hasLoadedWorkspaces)

        model.loadWorkspaces()

        XCTAssertTrue(model.hasLoadedWorkspaces)
        XCTAssertTrue(model.showsSessionSkeleton(alias: workspace.alias))
        try await waitUntil { model.sessionsByAlias[workspace.alias] != nil }
        XCTAssertFalse(model.showsSessionSkeleton(alias: workspace.alias))
    }

    @MainActor
    func testCachedSessionsDrawAtLaunchThenTheSweepReplacesThem() async throws {
        let workspace = Workspace(name: "acme", alias: "acme-devmachine")
        let cache = DataCache()
        cache.put(MachineDataKeys.sessions(workspace.alias), [TmuxSession(name: "cached", windows: 1, harnesses: [])])
        let model = AppModel(services: fixtureServices(
            workspaces: [workspace], sessions: [TmuxSession(name: "dash", windows: 1, harnesses: [])]), cache: cache)
        model.settings = .empty

        model.loadWorkspaces()

        XCTAssertEqual(model.sessionsByAlias[workspace.alias]?.map(\.name), ["cached"])
        XCTAssertFalse(model.showsSessionSkeleton(alias: workspace.alias))
        try await waitUntil { model.sessionsByAlias[workspace.alias]?.map(\.name) == ["dash"] }
        XCTAssertEqual(cache.cached(MachineDataKeys.sessions(workspace.alias))?.value.map(\.name), ["dash"])
    }

    @MainActor
    func testARefreshAfterSessionsArrivedNeverBringsTheSkeletonBack() async throws {
        let workspace = Workspace(name: "acme", alias: "acme-devmachine")
        let model = AppModel(services: fixtureServices(
            workspaces: [workspace], sessions: [TmuxSession(name: "dash", windows: 1, harnesses: [])]))
        model.settings = .empty
        model.loadWorkspaces()
        try await waitUntil { model.sessionsByAlias[workspace.alias] != nil }

        model.refreshAll()

        XCTAssertFalse(model.showsSessionSkeleton(alias: workspace.alias))
    }

    @MainActor
    func testAWorkspaceThatCannotBeReachedDropsItsSkeleton() {
        let model = AppModel(store: SessionStore(runner: UnreachableRunner()))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine"),
        ]
        XCTAssertTrue(model.showsSessionSkeleton(alias: "beta-devmachine"))
        model.refreshAll()

        let sweep = expectation(description: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sweep.fulfill() }
        wait(for: [sweep], timeout: 2)

        XCTAssertFalse(model.showsSessionSkeleton(alias: "acme-devmachine"))
        XCTAssertFalse(model.showsSessionSkeleton(alias: "beta-devmachine"))
    }

    @MainActor
    func testALockedAgentDropsTheSkeletonOfEveryWorkspaceTheSweepSkipped() {
        let model = AppModel(store: SessionStore(runner: AuthDeniedRunner()))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine"),
        ]
        model.refreshAll()

        let sweep = expectation(description: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sweep.fulfill() }
        wait(for: [sweep], timeout: 2)

        XCTAssertFalse(model.showsSessionSkeleton(alias: "acme-devmachine"))
        XCTAssertFalse(model.showsSessionSkeleton(alias: "beta-devmachine"))
    }

    @MainActor
    func testAnUnreachableHostTurnsEveryWorkspaceOnItOffline() {
        let model = AppModel(store: SessionStore(runner: UnreachableRunner()))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "beta", alias: "beta-devmachine"),
        ]
        model.refreshAll()

        let sweep = expectation(description: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sweep.fulfill() }
        wait(for: [sweep], timeout: 2)

        XCTAssertEqual(model.offlineAliases, ["acme-devmachine", "beta-devmachine"])
    }

    @MainActor
    func testTheAgentLockingDropsAnOlderOfflineMark() {
        let model = AppModel(store: SessionStore(runner: AuthDeniedRunner()))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.offlineAliases = ["acme-devmachine"]
        model.refreshAll()

        let sweep = expectation(description: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sweep.fulfill() }
        wait(for: [sweep], timeout: 2)

        XCTAssertTrue(model.offlineAliases.isEmpty)
    }

    @MainActor
    func testStackingTheLocalWorkspaceUsesItsOwnSessions() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.stackWorkspace(Workspace.local.alias)

        guard case let .stack(refs) = model.activePage else {
            return XCTFail("the local workspace did not open as a stack")
        }
        XCTAssertEqual(refs.map(\.name), ["Operator", "acme"])
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testALocalReferenceCarriesTheFolderItRunsIn() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")

        let kind = model.terminalKind(
            for: SessionRef(alias: Workspace.local.alias, name: "acme"))
        XCTAssertEqual(kind, .local(session: "acme", path: "/Users/alice/dev/acme"))
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testRenamingALocalSessionKeepsItsHandleAndItsTerminal() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")

        model.renameLocalSession(handle: "acme", to: "Client work")

        XCTAssertEqual(model.localSessions.map(\.name), ["Operator", "Client work"])
        XCTAssertEqual(model.localSessions.map(\.handle), ["Operator", "acme"])
        let kind = model.terminalKind(
            for: SessionRef(alias: Workspace.local.alias, name: "acme"))
        XCTAssertEqual(kind, .local(session: "acme", path: "/Users/alice/dev/acme"))
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testTheOperatorSessionCanBeRenamed() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.renameLocalSession(handle: Workspace.operatorSession, to: "Ops")
        XCTAssertEqual(model.localSessions.first?.name, "Ops")
        XCTAssertEqual(model.localSessions.first?.handle, Workspace.operatorSession)

        model.renameLocalSession(handle: Workspace.operatorSession, to: Workspace.operatorSession)
        XCTAssertEqual(model.localSessions.first?.name, Workspace.operatorSession)
    }

    @MainActor
    func testAnEmptyNameLeavesTheSessionAlone() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.renameLocalSession(handle: "acme", to: "   ")
        XCTAssertEqual(model.localSessions.map(\.name), ["Operator", "acme"])
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testRemovingASessionForgetsItsRename() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.renameLocalSession(handle: "acme", to: "Client work")
        model.removeLocalSession(handle: "acme")

        model.addLocalSession(path: "/Users/alice/dev/acme")
        XCTAssertEqual(model.localSessions.map(\.name), ["Operator", "acme"])
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testALocalSessionThatEndsLosesItsRowAndItsStackCell() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.stackWorkspace(Workspace.local.alias)

        model.sessionEnded(.local(session: "acme", path: "/Users/alice/dev/acme"))

        XCTAssertEqual(model.localSessions.map(\.handle), ["Operator"])
        guard case let .stack(refs) = model.activePage else {
            return XCTFail("the stack closed entirely")
        }
        XCTAssertEqual(refs.map(\.name), ["Operator"])
    }

    @MainActor
    func testTheLastSessionOfAStackClosesThePage() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.stackSessions([SessionRef(alias: "acme-devmachine", name: "dash")])

        model.sessionEnded(.remote(alias: "acme-devmachine", session: "dash"))

        XCTAssertNil(model.activePage)
    }

    @MainActor
    func testAnEndedSessionIsNoLongerSelected() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        XCTAssertEqual(model.selection, .localSession(name: "acme", path: "/Users/alice/dev/acme"))

        model.sessionEnded(.local(session: "acme", path: "/Users/alice/dev/acme"))

        XCTAssertNil(model.selection)
    }

    @MainActor
    func testAnEndedSessionForgetsItsRename() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.renameLocalSession(handle: "acme", to: "Client work")

        model.sessionEnded(.local(session: "acme", path: "/Users/alice/dev/acme"))

        model.addLocalSession(path: "/Users/alice/dev/acme")
        XCTAssertEqual(model.localSessions.map(\.name), ["Operator", "acme"])
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testAHiddenWorkspaceLeavesTheSidebarAndThePoll() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "initech", alias: "initech-devmachine"),
        ]
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", hiddenWorkspaces: ["initech-devmachine"])

        XCTAssertEqual(model.visibleWorkspaces.map(\.name), ["acme"])
        XCTAssertEqual(model.sidebarWorkspaces.map(\.name), ["acme", Workspace.local.name])
    }

    @MainActor
    func testHidingAWorkspaceForgetsItsSessionsAndSelection() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [Workspace(name: "initech", alias: "initech-devmachine")]
        model.sessionsByAlias["initech-devmachine"] = [
            TmuxSession(name: "main", windows: 1, harnesses: [])
        ]
        model.selection = .session(alias: "initech-devmachine", name: "main")
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", hiddenWorkspaces: ["initech-devmachine"])

        model.applyHiddenWorkspaces()

        XCTAssertNil(model.sessionsByAlias["initech-devmachine"])
        XCTAssertNil(model.selection)
        XCTAssertNil(model.selectionPollTarget)
    }

    @MainActor
    func testAVisibleWorkspaceIsUntouchedByHiding() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.sessionsByAlias["acme-devmachine"] = [
            TmuxSession(name: "dash", windows: 1, harnesses: [])
        ]
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", hiddenWorkspaces: ["initech-devmachine"])

        model.applyHiddenWorkspaces()

        XCTAssertEqual(model.sessionsByAlias["acme-devmachine"]?.count, 1)
    }

    @MainActor
    func testALocalSessionStoresItsDetectedHarnesses() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        let session = try! XCTUnwrap(model.localSessions.first { $0.handle == "acme" })

        XCTAssertEqual(model.localSessionHarnesses["acme"], nil)
        model.acceptLocalScanForTesting(
            sessions: [ZmxSession(name: "acme", pid: 4242, clients: 1, directory: "/live/acme")],
            harnesses: ["acme": [.claude]])

        XCTAssertEqual(model.localSessionHarnesses["acme"], [.claude])
        XCTAssertEqual(model.localWorkingDirectory(of: session), "/live/acme")
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testMaximizingALocalCellOpensItAsALocalSession() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.stackWorkspace(Workspace.local.alias)

        model.toggleMaximize()

        XCTAssertEqual(
            model.selection, .localSession(name: "Operator", path: model.localSessions[0].path))
        XCTAssertTrue(model.selectedSessions.isEmpty)
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testMaximizingARemoteCellKeepsItRemote() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.stackSessions([SessionRef(alias: "acme-devmachine", name: "dash")])

        model.toggleMaximize()

        XCTAssertEqual(model.selection, .session(alias: "acme-devmachine", name: "dash"))
        XCTAssertEqual(model.selectedSessions, [SessionRef(alias: "acme-devmachine", name: "dash")])
    }

    @MainActor
    func testALocalReferenceNeverBecomesARemoteRow() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")

        let item = model.sidebarItem(for: SessionRef(alias: Workspace.local.alias, name: "acme"))

        XCTAssertEqual(item, .localSession(name: "acme", path: "/Users/alice/dev/acme"))
        XCTAssertEqual(item.terminalKind, .local(session: "acme", path: "/Users/alice/dev/acme"))
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testMaximizingALocalSessionOpensTheLocalStack() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.addLocalSession(path: "/Users/alice/dev/acme")
        model.selection = .localSession(name: "acme", path: "/Users/alice/dev/acme")

        model.toggleMaximize()

        guard case let .stack(refs) = model.activePage else {
            return XCTFail("the local workspace did not open as a stack")
        }
        XCTAssertEqual(refs.map(\.alias), [Workspace.local.alias, Workspace.local.alias])
        model.removeLocalSession(handle: "acme")
    }

    @MainActor
    func testARowOfAHiddenWorkspaceIsNotShown() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [
            Workspace(name: "acme", alias: "acme-devmachine"),
            Workspace(name: "globex", alias: "globex-devmachine"),
        ]
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", hiddenWorkspaces: ["globex-devmachine"])

        XCTAssertTrue(model.showsOwner("acme"))
        XCTAssertFalse(model.showsOwner("globex"))
    }

    @MainActor
    func testARowWithNoOwnerOrAnUnknownOneStays() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        model.workspaces = [Workspace(name: "acme", alias: "acme-devmachine")]
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", hiddenWorkspaces: ["acme-devmachine"])

        // Not a context user at all: a system container, or the host itself.
        XCTAssertTrue(model.showsOwner(nil))
        XCTAssertTrue(model.showsOwner("root"))
        XCTAssertFalse(model.showsOwner("acme"))
    }

    @MainActor
    func testARemoteReferenceStaysRemote() {
        let model = AppModel(store: SessionStore(runner: BlockingRunner(output: "")))
        let kind = model.terminalKind(for: SessionRef(alias: "acme-devmachine", name: "dash"))
        XCTAssertEqual(kind, .remote(alias: "acme-devmachine", session: "dash"))
    }


    @MainActor
    func testATerminalWaitsForItsSizeBeforeTheProcessStarts() {
        let registry = TerminalRegistry.shared
        let kind = TerminalKind.local(session: "size-test", path: NSTemporaryDirectory())
        defer { registry.close(kind) }

        let view = registry.terminal(for: kind)
        // Built, but nothing runs in it yet: the view still has the placeholder
        // size, and a process started now would draw for the wrong geometry.
        XCTAssertNil(view.process.running ? true : nil)
    }

    func testCustomCommandOnLocalOpensANewSessionRunningItExactlyOnce() async throws {
        // A second local session under the same folder is born "base 2": the
        // custom command's own session, next to the one the selection points
        // at, the same numbering a duplicated session gets.
        let runner = HarnessProcessRunner(
            zmxListing: "name=base\tpid=100\tclients=1\tcwd=/Users/alice/dev/base\n"
                + "name=base 2\tpid=101\tclients=1\tcwd=/Users/alice/dev/base")
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: HarnessProcessRunner()),
            localRunner: runner,
            sessionCommandSender: sender,
            zmxPath: "/fixtures/zmx")
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com")
        model.addLocalSession(path: "/Users/alice/dev/base")

        model.openSession(in: Workspace.local.alias, startup: .command("CLAUDE_CONFIG_DIR=~/.claude-work claude"))

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "CLAUDE_CONFIG_DIR=~/.claude-work claude")
        guard case let .local(session, path) = sender.sent.first?.target else {
            return XCTFail("expected a local target")
        }
        XCTAssertEqual(session, "base 2")
        XCTAssertEqual(path, "/Users/alice/dev/base")
        model.removeLocalSession(handle: "base")
        model.removeLocalSession(handle: "base 2")
    }

    func testCustomCommandOnARemoteWorkspaceOpensANewSessionRunningItExactlyOnce() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: runner),
            sessionCommandSender: sender)
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com")

        model.openSession(in: "acme-devmachine", startup: .command("npm run dev"))

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "npm run dev")
        XCTAssertEqual(runner.callCount(for: "/usr/bin/ssh"), 1)
        guard case let .remote(alias, _) = sender.sent.first?.target else {
            return XCTFail("expected a remote target")
        }
        XCTAssertEqual(alias, "acme-devmachine")
    }

    func testPickingAHarnessRunsItsOwnStartupInsteadOfTheConfiguredOne() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(store: SessionStore(runner: runner), sessionCommandSender: sender)
        var settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com")
        settings.enabledHarnesses = [.claude, .codex]
        settings.remoteSessionProgram = .harness(.claude)
        model.settings = settings

        model.openSession(in: "acme-devmachine", startup: .program(.harness(.codex)))

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "codex")
    }

    func testPickingTerminalOpensAPlainShellEvenWhenAHarnessIsConfigured() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(store: SessionStore(runner: runner), sessionCommandSender: sender)
        var settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com")
        settings.enabledHarnesses = [.claude, .codex]
        settings.remoteSessionProgram = .harness(.claude)
        model.settings = settings

        model.openSession(in: "acme-devmachine", startup: .program(.terminal))

        try await waitUntil { runner.callCount(for: "/usr/bin/ssh") == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testNewRemoteSessionTypesTheWorkspaceCustomDefaultVerbatim() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(store: SessionStore(runner: runner), sessionCommandSender: sender)
        let typed = #"FOO="a b" npm run dev -- --port $PORT; `whoami`"#
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", remoteSessionProgram: .harness(.claude),
            workspaceSessionPrograms: ["acme-devmachine": .custom(typed)])

        model.confirmNewSession(alias: "acme-devmachine", name: "dev", directory: "~")

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, typed)
    }

    func testNewRemoteSessionInheritsTheFallbackCustomDefault() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(store: SessionStore(runner: runner), sessionCommandSender: sender)
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", remoteSessionProgram: .custom("htop"))

        model.confirmNewSession(alias: "beta-devmachine", name: "top", directory: "~")

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "htop")
    }

    func testStartingALocalSessionTypesTheCustomDefault() async throws {
        let runner = HarnessProcessRunner(
            zmxListing: "name=acme\tpid=100\tclients=1\tcwd=/Users/alice/dev/acme")
        let sender = RecordingSessionCommandSender()
        let model = AppModel(
            store: SessionStore(runner: HarnessProcessRunner()),
            localRunner: runner,
            sessionCommandSender: sender,
            zmxPath: "/fixtures/zmx")
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", localSessionProgram: .custom("npm run dev"))

        model.startProgram(in: .local(session: "acme", path: "/Users/alice/dev/acme"))

        try await waitUntil { sender.sent.count == 1 }
        XCTAssertEqual(sender.sent.first?.command, "npm run dev")
    }

    func testAnEmptyCustomDefaultOpensAPlainShell() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(store: SessionStore(runner: runner), sessionCommandSender: sender)
        model.settings = AppSettings(
            opsRepoPath: "/tmp", hostAlias: "devmachine", publicIP: "203.0.113.10",
            baseDomain: "example.com", remoteSessionProgram: .custom("  "))

        model.confirmNewSession(alias: "acme-devmachine", name: "shell", directory: "~")

        try await waitUntil { runner.callCount(for: "/usr/bin/ssh") == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testABlankCustomCommandOpensNothing() async throws {
        let runner = HarnessProcessRunner()
        let sender = RecordingSessionCommandSender()
        let model = AppModel(store: SessionStore(runner: runner), sessionCommandSender: sender)
        model.settings = .empty

        model.openSession(in: "acme-devmachine", startup: .command("   "))

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.callCount(for: "/usr/bin/ssh"), 0)
        XCTAssertTrue(sender.sent.isEmpty)
    }

}

private final class ThrowingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        lock.lock()
        calls += 1
        lock.unlock()
        throw NSError(domain: "test", code: 1)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

}


/// The ssh agent refusing to sign, which is what a locked 1Password does after
/// the Mac wakes: the host is fine, this Mac just cannot log in yet.
private final class AuthDeniedRunner: CommandRunner, @unchecked Sendable {
    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        try runCapturing(executable: executable, args: args, environment: environment).stdout
    }

    func runCapturing(executable: String, args: [String], environment: [String: String]?) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        ("", "alice@acme: Permission denied (publickey).", 255)
    }
}

private final class HostKeyRejectedRunner: CommandRunner, @unchecked Sendable {
    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        try runCapturing(executable: executable, args: args, environment: environment).stdout
    }

    func runCapturing(executable: String, args: [String], environment: [String: String]?) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        ("", "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.", 255)
    }
}

/// ssh itself failing, the way it does while the Mac is asleep: exit 255 and a
/// connection error, not a command that ran and failed.
private final class UnreachableRunner: CommandRunner, @unchecked Sendable {
    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        try runCapturing(executable: executable, args: args, environment: environment).stdout
    }

    func runCapturing(executable: String, args: [String], environment: [String: String]?) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        ("", "ssh: connect to host port 22: Operation timed out", 255)
    }
}
