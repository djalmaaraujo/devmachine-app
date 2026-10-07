import Foundation
import AppKit
import Combine
import DevmachineCore

/// One job the app is doing, shown as a card by `DMToastCard`. Every part of
/// the app that has to say "this is running" uses one of these, so there is a
/// single place a job is drawn and nothing pushes the layout around.
struct BGTask: Identifiable, Equatable {
    let id: UUID
    var label: String
    var completed: Int
    var total: Int
    /// Bytes read as "1048576 of 2097152", which says nothing. A job counted in
    /// bytes shows the bar alone.
    var showsCount: Bool = true
}

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let target: SidebarItem
    let badges: [HarnessBadgePresentation]
}

/// What a new session runs first: the workspace's configured program, one
/// picked for this session only, or a command typed by hand.
enum SessionStartup: Equatable {
    case configured
    case program(SessionLaunchChoice)
    case command(String)
}

extension SessionStartup {
    /// A harness that takes a first message on its command line starts
    /// asking `prompt`; any other program starts as it is, and the person
    /// types the ask.
    static func asking(_ prompt: String, with choice: SessionLaunchChoice, command: String?) -> SessionStartup {
        guard case let .harness(id) = choice, let command,
              let line = HarnessPrompt.command(command, harness: id, prompt: prompt) else { return .program(choice) }
        return .command(line)
    }
}

protocol SessionCommandSending: Sendable {
    func send(_ command: String, into target: CommandTarget) throws
}

extension HostRunner: SessionCommandSending {}

@MainActor
final class AppModel: ObservableObject {
    /// The one model the app builds, so code outside the view tree — the
    /// terminal key monitor — can report progress without being handed it.
    private(set) static weak var shared: AppModel?

    /// The background `devmachine` jobs the app runs against machines.
    let jobs = MachineJobCenter(cliVersion: { MachineReadinessStore.shared.snapshot?.cliVersion })

    /// Every workspace in `~/.ssh/config`, hidden ones included: Settings needs
    /// the whole list to offer the choice.
    @Published var workspaces: [Workspace] = []

    /// The workspaces in use. Everything else in the app reads this one, so a
    /// hidden workspace costs no row, no ssh and no mosh.
    var visibleWorkspaces: [Workspace] {
        WorkspaceVisibility.visible(workspaces, hidden: settings?.hiddenWorkspaces ?? [])
    }

    /// The sidebar list in the order the person dragged it into. Without a
    /// saved order: the ssh workspaces, then this Mac.
    var sidebarWorkspaces: [Workspace] {
        sidebarOrder.workspaces(visibleWorkspaces + [.local], id: \.alias)
    }

    /// Drag-and-drop order of workspaces and of the sessions inside each one.
    /// A demo never saves it: its workspaces are made up.
    @Published private(set) var sidebarOrder = SidebarOrder() {
        didSet {
            guard !DemoMode.isActive, let data = try? JSONEncoder().encode(sidebarOrder) else { return }
            defaults.set(data, forKey: AppModel.sidebarOrderKey)
        }
    }

    private static let sidebarOrderKey = "sidebarOrder"

    /// The 5s polls call this with nothing to change most of the time, and
    /// every write to a @Published re-renders the whole tree.
    private func updateSidebarOrder(_ change: (inout SidebarOrder) -> Void) {
        var next = sidebarOrder
        change(&next)
        if next != sidebarOrder { sidebarOrder = next }
    }

    /// A remote workspace's sessions in sidebar order.
    func sessions(in alias: String) -> [TmuxSession] {
        sidebarOrder.sessions(sessionsByAlias[alias] ?? [], in: alias, id: \.name)
    }

    /// One step of a sidebar drag. A session only ever moves inside its own
    /// workspace; anything else is refused.
    @discardableResult
    func moveInSidebar(_ dragging: SidebarDragItem, over target: SidebarDragItem) -> SidebarDrop.Action {
        let action = SidebarDrop.action(dragging: dragging, over: target)
        switch action {
        case let .moveWorkspace(alias, target):
            updateSidebarOrder {
                $0.moveWorkspace(alias, onto: target, live: sidebarWorkspaces.map(\.alias))
            }
        case let .moveSession(id, target, alias):
            let live = alias == Workspace.local.alias
                ? localSessions.map(\.handle)
                : sessions(in: alias).map(\.name)
            updateSidebarOrder { $0.moveSession(id, onto: target, in: alias, live: live) }
        case .stay, .refuse:
            break
        }
        return action
    }

    /// Sessions of the local workspace: the Operator shell plus whatever
    /// folders you added. The list is remembered, the shells are not — without
    /// a multiplexer a local shell ends when the app does.
    @Published private(set) var addedLocalSessions: [LocalSession] = [] {
        didSet { AppModel.writeLocalSessions(addedLocalSessions, to: defaults) }
    }

    /// Renames the sidebar shows, by handle. Kept apart from the stored list so
    /// the Operator session, which is not in that list, can be renamed too.
    @Published private(set) var localSessionNames: [String: String] = [:] {
        didSet { defaults.set(localSessionNames, forKey: AppModel.localNamesKey) }
    }

    /// The pane whose find bar is open, if any. ⌘F sets it for the terminal
    /// that holds the keyboard; Esc clears it.
    @Published var findTarget: TerminalKind?

    /// What `zmx ls` last reported and the active harnesses detected in each
    /// session, keyed by the multiplexer name.
    @Published private(set) var liveLocalSessions: [ZmxSession] = []
    @Published private(set) var localSessionHarnesses: [String: Set<HarnessID>] = [:]

    var localSessions: [LocalSession] {
        // Demo sessions never go through `addedLocalSessions`: that property
        // persists to `UserDefaults` on every change, and a demo session has
        // no business surviving into the next real launch.
        if DemoMode.isActive { return withoutHiddenOperator(DemoData.localSessions) }
        let remembered = [LocalSession(name: Workspace.operatorSession, path: operatorPath)]
            + addedLocalSessions
        let all = LocalSessionScan.merge(
            stored: remembered, live: liveLocalSessions, fallbackPath: NSHomeDirectory())
        let named = withoutHiddenOperator(all).map { session in
            guard let shown = localSessionNames[session.handle] else { return session }
            return LocalSession(handle: session.handle, name: shown, path: session.path)
        }
        return sidebarOrder.sessions(named, in: Workspace.local.alias, id: \.handle)
    }

    /// Filtered after the merge: a live Operator shell would otherwise come
    /// back as a session started outside the app.
    private func withoutHiddenOperator(_ sessions: [LocalSession]) -> [LocalSession] {
        guard settings?.operatorSessionEnabled == false else { return sessions }
        return sessions.filter { $0.handle != Workspace.operatorSession }
    }

    private var operatorLaunchInFlight = false

    /// Every way into the Operator comes here (sidebar, ⌘K). A shell the
    /// multiplexer already holds is only shown. Otherwise it asks which
    /// installed harness to start, the last answer selected.
    func openOperatorSession() {
        guard !operatorLaunchInFlight,
              let session = localSessions.first(where: { $0.handle == Workspace.operatorSession })
        else { return }
        let item = SidebarItem.localSession(name: session.handle, path: session.path)
        let kind = TerminalKind.local(session: session.handle, path: session.path)
        if TerminalRegistry.shared.isStarted(kind) {
            selection = item
            return
        }
        operatorLaunchInFlight = true
        let facade = harnessSettingsFacade
        let saved = settings.flatMap { facade.operatorProgram(for: $0) }
        let runner = localRunner
        let zmxPath = DemoMode.isActive ? nil : zmxPath
        Task.detached {
            let isRunning = zmxPath.map { Self.multiplexerHolds(session.handle, zmx: $0, runner: runner) } ?? false
            let installed = facade.installedHarnesses.map(\.id)
            let plan = OperatorLaunch.plan(isRunning: isRunning, saved: saved, installed: installed)
            await MainActor.run {
                self.operatorLaunchInFlight = false
                self.apply(plan, item: item)
            }
        }
    }

    nonisolated private static func multiplexerHolds(_ session: String, zmx: String, runner: any CommandRunner) -> Bool {
        let socketDirectory = Zmx.socketDirectory()
        let name = Zmx.sessionName(from: session, socketDirectory: socketDirectory)
        let listing = (try? runner.run(
            executable: zmx, args: Zmx.listArguments, environment: ["ZMX_DIR": socketDirectory])) ?? ""
        return ZmxListParser.parse(listing).contains { $0.name == name }
    }

    private func apply(_ plan: OperatorLaunch, item: SidebarItem) {
        switch plan {
        case .attach:
            selection = item
        case let .choose(harnesses, last):
            selection = nil
            activePage = .operatorChooser(harnesses, last: last)
        case let .start(choice):
            selection = item
            startOperator(item, startup: .program(choice))
        }
    }

    /// The chooser's answer becomes the Operator's program. Only the first
    /// pick asks the harness what the folder is for.
    func chooseOperatorProgram(_ choice: SessionLaunchChoice, in store: SettingsStore = .shared) {
        let firstPick = (store.settings ?? settings)?.operatorProgram == nil
        if var current = store.settings {
            current.operatorProgram = choice
            store.settings = current
        }
        settings?.operatorProgram = choice
        guard let session = localSessions.first(where: { $0.handle == Workspace.operatorSession }) else { return }
        let item = SidebarItem.localSession(name: session.handle, path: session.path)
        selection = item
        guard firstPick else {
            startOperator(item, startup: .program(choice))
            return
        }
        startOperator(item, startup: .asking(
            HarnessPrompt.operatorIntro, with: choice, command: harnessSettingsFacade.startupCommand(for: choice)))
    }

    private func startOperator(_ item: SidebarItem, startup: SessionStartup) {
        guard !DemoMode.isActive, case let .localSession(name, path) = item else { return }
        startProgram(in: .local(session: name, path: path), startup: startup)
    }

    /// Turning the Operator off hides it, never ends it: the multiplexer keeps
    /// its shell, and turning it on again shows the same session.
    func applyOperatorVisibility() {
        guard settings?.operatorSessionEnabled == false else { return }
        if case let .localSession(name, _) = selection, name == Workspace.operatorSession { selection = nil }
        if case .operatorChooser = activePage { activePage = nil }
    }

    /// The context users behind the workspaces still on: what Stats and the
    /// subdomain list are allowed to show. A row the host cannot attribute to
    /// any of them (a system container, the apex site) is left alone — hiding
    /// what we cannot name would hide the machine itself.
    var visibleUsers: Set<String> {
        Set(visibleWorkspaces.map(\.name))
    }

    func showsOwner(_ owner: String?) -> Bool {
        guard let owner, knownUsers.contains(owner) else { return true }
        return visibleUsers.contains(owner)
    }

    /// Every context user the app knows of, hidden ones included.
    var knownUsers: Set<String> {
        Set(workspaces.map(\.name))
    }

    /// True while the multiplexer has this session, so the sidebar can tell a
    /// shell that is running from one that only exists in the app's list.
    func localSessionIsLive(_ session: LocalSession) -> Bool {
        let name = LocalSessionScan.multiplexerName(of: session)
        return liveLocalSessions.contains { $0.name == name }
    }

    /// Where the shell is now, which is not always where it started: the
    /// multiplexer reports the live folder, and that is what the context engine
    /// has to read.
    func localWorkingDirectory(of session: LocalSession) -> String? {
        let name = LocalSessionScan.multiplexerName(of: session)
        return liveLocalSessions.first { $0.name == name }?.directory
    }

    func localSessionHasClaude(_ session: LocalSession) -> Bool {
        localSessionHarnesses[LocalSessionScan.multiplexerName(of: session)]?.contains(.claude)
            == true
    }

    func badges(for session: TmuxSession) -> [HarnessBadgePresentation] {
        sessionHarnessFacade.badges(for: session.harnesses)
    }

    func badges(for session: LocalSession) -> [HarnessBadgePresentation] {
        let name = LocalSessionScan.multiplexerName(of: session)
        return sessionHarnessFacade.badges(for: localSessionHarnesses[name] ?? [])
    }

    func uploadStoragePolicy(for kind: TerminalKind) -> UploadStoragePolicy {
        let harnesses: Set<HarnessID>
        switch kind {
        case let .remote(alias, session):
            harnesses = sessionsByAlias[alias]?.first { $0.name == session }?.harnesses ?? []
        case let .local(session, _):
            let name = Zmx.sessionName(from: session, socketDirectory: Zmx.socketDirectory())
            harnesses = localSessionHarnesses[name] ?? []
        }
        return sessionHarnessFacade.uploadStoragePolicy(for: harnesses)
    }

    var sessionCount: Int {
        sessionsByAlias.values.reduce(0) { $0 + $1.count } + localSessions.count
    }

    var harnessSessionCount: Int {
        let remote = sessionsByAlias.values.reduce(0) { count, sessions in
            count + sessions.filter { !$0.harnesses.isEmpty }.count
        }
        let local = localSessions.filter { !badges(for: $0).isEmpty }.count
        return remote + local
    }

    /// Reads the multiplexer's own list, then one `ps` to see what runs inside
    /// each session. Both are local and cheap; neither touches the network.
    func scanLocalSessions() {
        guard !localScanInFlight else { return }
        localScanInFlight = true
        let source = services.sessionSource
        let settings = settings ?? .empty
        Task.detached {
            let snapshot = try? source.localSessions(settings: settings)
            await MainActor.run {
                self.localScanInFlight = false
                guard let snapshot else { return }
                if self.liveLocalSessions != snapshot.sessions {
                    self.liveLocalSessions = snapshot.sessions
                    let present = self.localSessions.map(\.handle)
                    self.updateSidebarOrder { $0.keepSessions(present, in: Workspace.local.alias) }
                }
                if self.localSessionHarnesses != snapshot.harnesses {
                    self.localSessionHarnesses = snapshot.harnesses
                }
                // The working directory can change even when harnesses do not.
                self.syncContext()
            }
        }
    }

    private var localScanInFlight = false

    /// Fills what a scan would have found, for tests that must not run `zmx`.
    func acceptLocalScanForTesting(
        sessions: [ZmxSession], harnesses: [String: Set<HarnessID>]
    ) {
        liveLocalSessions = sessions
        localSessionHarnesses = harnesses
    }

    private var operatorPath: String {
        settings?.opsRepoPath ?? NSHomeDirectory()
    }

    /// Adds the folder as a session and opens it. A repeated folder is a
    /// separate session, numbered, rather than a jump to the existing one:
    /// two shells in one repository is a normal thing to want.
    func addLocalSession(path: String) {
        // Numbered against the handles, never the sidebar names: a renamed
        // session hides its handle, and a second session born under that same
        // handle is one row the multiplexer and the registry cannot tell apart.
        let handle = LocalSessionNaming.name(for: path, existing: localSessions.map(\.handle))
        addedLocalSessions.append(LocalSession(name: handle, path: path))
        selection = .localSession(name: handle, path: path)
        startProgram(in: .local(session: handle, path: path))
    }

    /// Types the startup line once the session exists. A local session is born
    /// when its pane mounts, not when the row is added, so the line waits for
    /// the multiplexer to list it.
    func startProgram(in target: CommandTarget, startup: SessionStartup = .configured) {
        guard let line = startupLine(startup, for: target) else { return }
        let sender = sessionCommandSender
        let runner = localRunner
        let zmxPath = zmxPath
        Task.detached {
            guard case let .local(session, _) = target else {
                try? sender.send(line, into: target)
                return
            }
            let socketDirectory = Zmx.socketDirectory()
            let name = Zmx.sessionName(from: session, socketDirectory: socketDirectory)
            guard let zmx = zmxPath else { return }
            for _ in 0..<30 {
                let listing = (try? runner.run(
                    executable: zmx, args: Zmx.listArguments,
                    environment: ["ZMX_DIR": socketDirectory])) ?? ""
                if ZmxListParser.parse(listing).contains(where: { $0.name == name }) {
                    // The shell prints its prompt after the socket exists; a
                    // line typed before that is swallowed by the terminal setup.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    try? sender.send(line, into: target)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func removeLocalSession(handle: String) {
        guard let s = localSessions.first(where: { $0.handle == handle }) else { return }
        TerminalRegistry.shared.close(.local(session: s.handle, path: s.path))
        PreviewStore.shared.closeSession(SessionRef(alias: Workspace.local.alias, name: s.handle))
        // Closing the pane only drops this app's client; the multiplexer would
        // keep the shell running with nothing pointing at it.
        TerminalRegistry.shared.killLocalSession(named: s.handle)
        addedLocalSessions.removeAll { $0.handle == handle }
        let multiplexerName = LocalSessionScan.multiplexerName(of: s)
        liveLocalSessions.removeAll { $0.name == multiplexerName }
        localSessionHarnesses[multiplexerName] = nil
        localSessionNames[handle] = nil
        updateSidebarOrder { $0.removeSession(handle, in: Workspace.local.alias) }
        if selection == .localSession(name: s.handle, path: s.path) { selection = nil }
    }

    /// Only the sidebar name changes: the shell keeps running under the handle
    /// it was created with, because the multiplexer cannot rename a session.
    func renameLocalSession(handle: String, to newName: String) {
        pendingLocalRename = nil
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        guard localSessions.contains(where: { $0.handle == handle }) else { return }
        if clean == handle {
            localSessionNames[handle] = nil
        } else {
            localSessionNames[handle] = String(clean.prefix(40))
        }
    }

    private static let localSessionsKey = "localSessions"
    private static let localNamesKey = "localSessionNames"

    private static func readLocalSessions(from defaults: UserDefaults) -> [LocalSession] {
        guard let data = defaults.data(forKey: localSessionsKey),
              let list = try? JSONDecoder().decode([LocalSession].self, from: data)
        else { return [] }
        return list
    }

    private static func writeLocalSessions(_ list: [LocalSession], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: localSessionsKey)
    }
    @Published var sessionsByAlias: [String: [TmuxSession]] = [:]
    @Published var offlineAliases: Set<String> = []
    /// True once the workspace list has been read at launch.
    @Published private(set) var hasLoadedWorkspaces = false
    /// Workspaces whose session read has come back at least once, with a list
    /// or with a failure.
    @Published private(set) var answeredAliases: Set<String> = []

    /// The sidebar holds a workspace's place with placeholder rows until its
    /// first read answers. A paused sweep will not read it soon, so a
    /// workspace waiting on the pause shows as it is instead.
    func showsSessionSkeleton(alias: String) -> Bool {
        !answeredAliases.contains(alias) && !isPollingPaused
    }

    private func markAnswered(_ alias: String) {
        if !answeredAliases.contains(alias) {
            answeredAliases.insert(alias)
        }
    }

    /// The sweep and an image transfer are jobs like any other: they are cards
    /// in the corner, not a strip above the sidebar. That strip had no fixed
    /// height, so every sweep pushed the whole list down and back.
    private var sweepTaskID: UUID?

    func beginTransfer(label: String, total: Int) -> UUID {
        beginTask(label: label, total: total, showsCount: false)
    }

    func advanceTransfer(_ id: UUID, done: Int) {
        setTask(id, completed: done)
    }

    func endTransfer(_ id: UUID) {
        finishTask(id)
    }
    @Published var selection: SidebarItem? = nil {
        didSet {
            if let selection {
                activePage = nil
                TerminalRegistry.shared.requestFocus(selection.terminalKind)
            }
            // Leaving the session list (ops shell, Home) drops the session
            // highlight: two places lit at once reads as being in two sessions.
            if case .session = selection {} else {
                selectedSessions = []
                selectionAnchor = nil
            }
            PreviewStore.shared.setOwner(selection?.sessionRef)
            syncContext()
            recordNavigation()
        }
    }
    @Published var activePage: AppPage? = nil {
        didSet {
            if activePage == .addMachine, oldValue != .addMachine {
                addMachineOpenedFromSettings = oldValue == .setup
            }
            syncContext()
            recordNavigation()
            // Coming back from a page leaves the pane exactly as it was, so the
            // program inside is never told to draw again and the screen stays
            // stale. Same repaint the app asks for after a pane is put away.
            guard activePage == nil, oldValue != nil, let selection else { return }
            TerminalRegistry.shared.requestRepaint(selection.terminalKind)
        }
    }
    /// True while the devmachine CLI executable is not found on disk. The gate
    /// page owns the whole window while this is true — no background service
    /// (session sweep, stats, context) is started until this clears.
    @Published private(set) var cliMissing = false
    /// The first-run setup owns the window: no CLI, or no saved settings
    /// yet, and the person has not skipped it (`launchRoute`).
    @Published private(set) var showsOnboarding = false
    @Published var settings: AppSettings? = nil
    /// What the CLI answered about this Mac's setup — the config folder,
    /// admin machine, base domain, and workspace aliases Setup shows
    /// read-only instead of asking the person to type them.
    @Published private(set) var detected: CLIDetectedSettings = .empty
    /// Why a workspace's session list could not be read, shown in its place
    /// instead of an empty list. Cleared by the next list that answers.
    @Published private(set) var sessionProblems: [String: SessionProblem] = [:]
    /// Whether the sidebar's Subdomains icon has anything to show for: at
    /// least one configured machine has Caddy. Starts `true` so the icon does
    /// not flash away before the first check answers.
    @Published private(set) var hasCaddyMachine = true
    @Published var stackCellSizes: [String: StackCellSize] = AppModel.loadStackCellSizes() {
        didSet { AppModel.saveStackCellSizes(stackCellSizes) }
    }
    @Published var pendingNewSessionAlias: String? = nil
    @Published var showNewSessionChooser = false
    /// The workspace whose "Custom command…" sheet is open.
    @Published var pendingCustomCommandAlias: String? = nil
    @Published var pendingRename: (alias: String, old: String)? = nil
    @Published var pendingLocalRename: (handle: String, current: String)? = nil
    @Published var pendingBulkDelete: [SessionRef]? = nil
    /// The session ⌘W or the sidebar asked to end, waiting for a confirm.
    @Published var pendingEndSession: SessionEndRequest? = nil
    @Published var selectedSessions: Set<SessionRef> = []
    @Published var activeTasks: [BGTask] = []
    @Published var showCommandPalette = false
    /// The file finder, opened over any session.
    @Published var showFileSearch = false
    @Published var showShortcuts = false
    /// The workspace whose "Publish a port…" sheet should open.
    @Published var pendingPublishWorkspace: String?
    /// Asks the Subdomains page to open its Add subdomain sheet once shown.
    @Published var pendingAddSubdomain = false
    /// Settings → Workspaces should open its New workspace form.
    @Published var pendingNewWorkspace = false
    /// The Settings pane to open on, read once by the Settings page.
    @Published var requestedSettingsSection: SettingsSection?
    /// Settings → Packages should open with its Machine dropdown on this one.
    @Published var requestedPackagesMachine: String?
    /// Settings → Packages should open with its Workspace dropdown on this one.
    @Published var requestedPackagesWorkspace: String?
    /// The machine whose host key review is open, as a sheet over whatever
    /// screen asked for it.
    @Published var hostKeyMachine: String?
    var selectionAnchor: SessionRef? = nil

    @Published var sidebarCollapsed: Bool = (UserDefaults.standard.object(forKey: "sidebarCollapsed") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") }
    }
    /// Points at 100% text size; drawn at `DMMetrics.pt(_:)`, so the pane grows with the text.
    @Published var sidebarWidth: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth"))
        return DMPaneWidth.sidebar.contains(saved) ? saved : DMPaneWidth.sidebar.ideal
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth") }
    }

    @Published var contextCollapsed: Bool = (UserDefaults.standard.object(forKey: "contextCollapsed") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(contextCollapsed, forKey: "contextCollapsed")
            syncContext()
        }
    }
    /// Points at 100% text size, like `sidebarWidth`.
    @Published var contextWidth: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "contextWidth"))
        return DMPaneWidth.context.contains(saved) ? saved : DMPaneWidth.context.ideal
    }() {
        didSet { UserDefaults.standard.set(Double(contextWidth), forKey: "contextWidth") }
    }
    @Published var contextTab: ContextTab =
        ContextTab(rawValue: UserDefaults.standard.string(forKey: "contextTab") ?? "") ?? .context {
        didSet {
            UserDefaults.standard.set(contextTab.rawValue, forKey: "contextTab")
            syncContext()
        }
    }
    let context: ContextStore
    let cache: DataCache

    private let store: SessionStore
    private let services: DevmachineServices
    private let harnessSettingsFacade: HarnessSettingsFacade
    private let sessionHarnessFacade: SessionHarnessFacade
    private let localRunner: any CommandRunner
    private let sessionCommandSender: any SessionCommandSending
    private let zmxPath: String?
    private let sessionSuffix: @Sendable () -> String
    private let cliAvailabilityCheck: @Sendable () -> Bool
    private let detectSettings: @Sendable () -> CLIDetectedSettings
    private var navigationHistory = NavigationHistory(initial: .home)
    private var isRestoringNavigation = false
    private var selectionPollTimer: Timer? = nil
    private var selectionPollAlias: String? = nil
    private var refreshingAliases: Set<String> = []
    private var sweepInFlight = false
    private var sweepTimer: Timer? = nil
    private var localScanTimer: Timer? = nil
    private var pollPausedUntil = Date.distantPast
    // Workspaces that appeared while the app was open and have not logged in
    // yet: the CLI writes the alias before the sync creates the account.
    private var awaitingFirstLogin: Set<String> = []
    private let defaults: UserDefaults

    /// `swift test` runs unsandboxed on the developer's own Mac, so
    /// `UserDefaults.standard` is a real, persistent domain — a session added
    /// by one test run stays on disk and leaks into the next. Under XCTest
    /// this hands out a fresh, never-reused suite per `AppModel` instead, so
    /// no test ever sees another run's (or the real app's) local sessions.
    ///
    /// `XCTestConfigurationFilePath` is only set when Xcode launches the test
    /// host; the `swift test` CLI never sets it, so this used to read false
    /// under plain `swift test` and every `AppModel()` fell through to the
    /// real, shared `UserDefaults.standard` — the whole `AppModelTests` class
    /// sharing one on-disk domain, and failing depending on run order.
    /// `NSClassFromString` finds the XCTest framework itself, which is loaded
    /// under both.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private static func defaultDefaults() -> UserDefaults {
        guard isRunningTests else { return .standard }
        return UserDefaults(suiteName: "app.devmachine.mac.tests.\(UUID().uuidString)") ?? .standard
    }

    init(
        store: SessionStore = SessionStore(runner: ProcessRunner()),
        services: DevmachineServices? = nil,
        harnessSettingsFacade: HarnessSettingsFacade = HarnessSettingsFacade(),
        localRunner: any CommandRunner = ProcessRunner(),
        sessionCommandSender: any SessionCommandSending = HostRunner(),
        zmxPath: String? = LocalTools.zmxPath(),
        sessionSuffix: @escaping @Sendable () -> String = {
            String(UUID().uuidString.prefix(2)).lowercased()
        },
        cliAvailabilityCheck: @escaping @Sendable () -> Bool = {
            (try? DevmachineCLI.resolve()) != nil
        },
        detectSettings: @escaping @Sendable () -> CLIDetectedSettings = {
            CLIAutoDetect.detect(cli: { try DevmachineCLI.resolve() })
        },
        defaults: UserDefaults = AppModel.defaultDefaults(),
        cache: DataCache = DataCache()
    ) {
        self.cache = cache
        self.store = store
        self.defaults = defaults
        self.addedLocalSessions = AppModel.readLocalSessions(from: defaults)
        self.localSessionNames = defaults.dictionary(forKey: AppModel.localNamesKey) as? [String: String] ?? [:]
        if let data = defaults.data(forKey: AppModel.sidebarOrderKey),
           let saved = try? JSONDecoder().decode(SidebarOrder.self, from: data) {
            self.sidebarOrder = saved
        }
        let services = services ?? DevmachineServices(sessionSource: CommandSessionSource(
            store: store, localRunner: localRunner, zmxPath: zmxPath,
            facade: SessionHarnessFacade(registry: harnessSettingsFacade.registry)))
        self.services = services
        self.context = ContextStore(services: services, cache: cache)
        self.harnessSettingsFacade = harnessSettingsFacade
        self.sessionHarnessFacade = SessionHarnessFacade(registry: harnessSettingsFacade.registry)
        self.localRunner = localRunner
        self.sessionCommandSender = sessionCommandSender
        self.zmxPath = zmxPath
        self.sessionSuffix = sessionSuffix
        self.cliAvailabilityCheck = cliAvailabilityCheck
        self.detectSettings = detectSettings
        AppModel.shared = self
        observeWake()
        TerminalRegistry.shared.onSessionEnded = { [weak self] kind in
            self?.sessionEnded(kind)
        }
    }

    /// Hiding a workspace has to cost nothing at once, not at the next restart:
    /// its panes are closed, which ends the mosh or ssh they hold, its sessions
    /// are forgotten, and the poll has nothing left to visit.
    func applyHiddenWorkspaces() {
        let hidden = settings?.hiddenWorkspaces ?? []
        guard !hidden.isEmpty else { return }
        for alias in hidden where WorkspaceVisibility.isHidden(alias, hidden: hidden) {
            for session in sessionsByAlias[alias] ?? [] {
                drop(SessionRef(alias: alias, name: session.name),
                     item: .session(alias: alias, name: session.name))
            }
            TerminalRegistry.shared.closeWorkspace(alias: alias)
            PreviewStore.shared.closeWorkspace(alias: alias)
            updateSidebarOrder { $0.removeWorkspace(alias) }
            sessionsByAlias[alias] = nil
            offlineAliases.remove(alias)
            if selectionPollAlias == alias {
                selectionPollTimer?.invalidate()
                selectionPollTimer = nil
                selectionPollAlias = nil
            }
        }
        if case let .session(alias, _) = selection,
           WorkspaceVisibility.isHidden(alias, hidden: hidden) {
            selection = nil
        }
        syncContext()
    }

    /// A session that ended (`exit`) leaves no pane behind: the row goes, the
    /// stack closes over the gap, and the selection moves off it.
    func sessionEnded(_ kind: TerminalKind) {
        switch kind {
        case let .local(handle, path):
            addedLocalSessions.removeAll { $0.handle == handle }
            localSessionNames[handle] = nil
            let multiplexerName = Zmx.sessionName(
                from: handle, socketDirectory: Zmx.socketDirectory())
            liveLocalSessions.removeAll {
                $0.name == multiplexerName
            }
            localSessionHarnesses[multiplexerName] = nil
            drop(SessionRef(alias: Workspace.local.alias, name: handle),
                 item: .localSession(name: handle, path: path))
        case let .remote(alias, session):
            drop(SessionRef(alias: alias, name: session),
                 item: .session(alias: alias, name: session))
        }
    }

    private func drop(_ ref: SessionRef, item: SidebarItem) {
        if case let .stack(refs) = activePage, refs.contains(ref) {
            let left = refs.filter { $0 != ref }
            activePage = left.isEmpty ? nil : .stack(left)
        }
        selectedSessions.remove(ref)
        if selectionAnchor == ref { selectionAnchor = nil }
        if selection == item { selection = nil }
        TerminalRegistry.shared.close(item.terminalKind)
    }

    /// Sessions this app still shows for a workspace that the workspace itself
    /// no longer has: killed from another client, or ended with `exit`.
    /// New names from renames made through the app, and when. A poll that
    /// lands before tmux has renamed lists neither name; without this it would
    /// forget the place the rename just moved over.
    private var renamesInFlight: [SessionRef: Date] = [:]
    private static let renameGrace: TimeInterval = 30

    private func dropMissingSessions(alias: String, present: [TmuxSession]) {
        let names = Set(present.map(\.name))
        let now = Date()
        renamesInFlight = renamesInFlight.filter { ref, started in
            !(ref.alias == alias && names.contains(ref.name))
                && now.timeIntervalSince(started) < Self.renameGrace
        }
        let renaming = renamesInFlight.keys.filter { $0.alias == alias }.map(\.name)
        updateSidebarOrder { $0.keepSessions(names.union(renaming), in: alias) }
        var refs: [SessionRef] = []
        if case let .stack(stacked) = activePage {
            refs += stacked.filter { $0.alias == alias && !names.contains($0.name) }
        }
        if case let .session(selectedAlias, name) = selection,
           selectedAlias == alias, !names.contains(name) {
            refs.append(SessionRef(alias: alias, name: name))
        }
        for ref in Set(refs) {
            drop(ref, item: .session(alias: ref.alias, name: ref.name))
        }
    }

    var hasSelectionPollTimer: Bool { selectionPollTimer != nil }
    var selectionPollTarget: String? { selectionPollAlias }

    func newSession(alias: String) {
        pendingNewSessionAlias = alias
    }

    /// Opens a brand new session in one workspace from the sidebar's "+"
    /// menu, running the program or command picked there instead of the
    /// configured default.
    func openSession(in alias: String, startup: SessionStartup) {
        if case let .command(raw) = startup, CustomSessionCommand.normalized(raw) == nil { return }
        if alias == Workspace.local.alias {
            openLocalSession(startup: startup)
        } else {
            let directory = "~"
            let name = automaticSessionName(
                directory: directory, existing: Set(sessionsByAlias[alias]?.map(\.name) ?? []))
            createRemoteSession(alias: alias, name: name, directory: directory, startup: startup)
        }
    }

    /// Starts in the current local session's own folder when there is one
    /// (mirroring a duplicated session), else the home directory.
    private func openLocalSession(startup: SessionStartup) {
        let path: String
        if case let .localSession(name, _) = selection,
           let existing = localSessions.first(where: { $0.handle == name }) {
            path = localWorkingDirectory(of: existing) ?? existing.path
        } else {
            path = NSHomeDirectory()
        }
        let handle = LocalSessionNaming.name(for: path, existing: localSessions.map(\.handle))
        addedLocalSessions.append(LocalSession(name: handle, path: path))
        selection = .localSession(name: handle, path: path)
        startProgram(in: .local(session: handle, path: path), startup: startup)
    }

    /// A new local session in `path`, shown at once in place of the page
    /// open now, running what `startup` says.
    func openLocalSession(at path: String, startup: SessionStartup) {
        let handle = LocalSessionNaming.name(for: path, existing: localSessions.map(\.handle))
        addedLocalSessions.append(LocalSession(name: handle, path: path))
        activePage = nil
        selection = .localSession(name: handle, path: path)
        startProgram(in: .local(session: handle, path: path), startup: startup)
    }

    /// The first line typed into a new session, or nil for a plain shell.
    private func startupLine(_ startup: SessionStartup, for target: CommandTarget) -> String? {
        switch startup {
        case .configured:
            guard let settings else { return nil }
            switch target {
            case .local:
                return harnessSettingsFacade.startupCommand(
                    for: harnessSettingsFacade.localSessionProgram(for: settings))
            case let .remote(alias, _):
                return harnessSettingsFacade.startupCommand(for: settings.sessionProgram(for: alias))
            }
        case let .program(choice):
            return harnessSettingsFacade.startupCommand(for: choice)
        case let .command(raw):
            return CustomSessionCommand.normalized(raw)
        }
    }

    /// ⌘N behaves like a terminal tab: duplicate the current location without
    /// asking, or ask for a destination when no terminal is actually visible.
    func requestQuickSession() {
        requestQuickSession(focusedRef: FocusedTerminal.ref())
    }

    func requestQuickSession(focusedRef: SessionRef?) {
        let item: SidebarItem?
        if activePage == nil {
            item = selection
        } else if case let .stack(refs) = activePage,
                  let ref = focusedRef.flatMap({ refs.contains($0) ? $0 : nil }) ?? refs.first {
            item = sidebarItem(for: ref)
        } else {
            item = nil
        }
        guard let target = commandTarget(for: item) else {
            showNewSessionChooser = true
            return
        }
        switch target {
        case let .local(_, path):
            addQuickLocalSession(path: path)
        case let .remote(alias, session):
            duplicateRemoteSession(alias: alias, session: session)
        }
    }

    func createQuickSession(destinationAlias: String, directory: String) {
        let path = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        showNewSessionChooser = false
        newSessionDirectory = path
        if destinationAlias == Workspace.local.alias {
            addQuickLocalSession(path: path)
        } else {
            let name = automaticSessionName(
                directory: path,
                existing: Set(sessionsByAlias[destinationAlias]?.map(\.name) ?? []))
            createRemoteSession(alias: destinationAlias, name: name, directory: path)
        }
    }

    private func addQuickLocalSession(path: String) {
        let name = automaticSessionName(
            directory: path, existing: Set(localSessions.map(\.handle)))
        addedLocalSessions.append(LocalSession(name: name, path: path))
        selection = .localSession(name: name, path: path)
        startProgram(in: .local(session: name, path: path))
    }

    private func duplicateRemoteSession(alias: String, session: String) {
        let taskID = beginTask(label: "Creating session", total: 1)
        let store = self.store
        Task.detached {
            let reported = try? store.run(
                alias: alias, command: RemoteCommands.sessionDirectory(session: session))
            let path = reported?.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                let directory = (path?.isEmpty == false ? path : nil) ?? "~"
                let name = self.automaticSessionName(
                    directory: directory,
                    existing: Set(self.sessionsByAlias[alias]?.map(\.name) ?? []))
                self.createRemoteSession(
                    alias: alias, name: name, directory: directory, taskID: taskID)
            }
        }
    }

    private func automaticSessionName(directory: String, existing: Set<String>) -> String {
        var candidate = ""
        for _ in 0..<8 {
            candidate = SessionName.automatic(directory: directory, suffix: sessionSuffix())
            if !existing.contains(candidate) { return candidate }
        }
        var number = 2
        while existing.contains("\(candidate)-\(number)") { number += 1 }
        return "\(candidate)-\(number)"
    }

    /// Types text where a session is waiting for input, without sending it.
    func typeInSession(_ target: CommandTarget, text: String) {
        let host = HostRunner()
        Task.detached {
            try? host.type(text, into: target)
        }
    }

    func showPage(_ page: AppPage) {
        activePage = page
    }

    func stackSessions(_ refs: [SessionRef]) {
        guard let first = refs.first else { return }
        activePage = .stack(refs)
        TerminalRegistry.shared.requestFocus(.remote(alias: first.alias, session: first.name))
    }

    func stackWorkspace(_ alias: String) {
        let refs = alias == Workspace.local.alias
            ? localSessions.map { SessionRef(alias: alias, name: $0.handle) }
            : sessions(in: alias).map { SessionRef(alias: alias, name: $0.name) }
        stackSessions(refs)
    }

    /// Which terminal a reference stands for. The local workspace is the one
    /// whose sessions run here, and those need the folder they started in.
    func terminalKind(for ref: SessionRef) -> TerminalKind {
        guard ref.alias == Workspace.local.alias else {
            return .remote(alias: ref.alias, session: ref.name)
        }
        let path = localSessions.first { $0.handle == ref.name }?.path ?? NSHomeDirectory()
        return .local(session: ref.name, path: path)
    }

    /// What a session is called on screen. A local session keeps its handle as
    /// a reference, so the name has to be looked up.
    func displayName(for ref: SessionRef) -> String {
        guard ref.alias == Workspace.local.alias else { return ref.name }
        return localSessions.first { $0.handle == ref.name }?.name ?? ref.name
    }

    func isStacked(_ ref: SessionRef) -> Bool {
        if case let .stack(refs) = activePage { return refs.contains(ref) }
        return false
    }

    func isWorkspaceStacked(_ alias: String) -> Bool {
        guard case let .stack(refs) = activePage, !refs.isEmpty else { return false }
        return refs.allSatisfy { $0.alias == alias }
    }

    func stackCellSize(_ ref: SessionRef) -> StackCellSize {
        stackCellSizes[Self.stackCellKey(ref)] ?? .auto
    }

    func cycleStackCellSize(_ ref: SessionRef) {
        let key = Self.stackCellKey(ref)
        stackCellSizes[key] = stackCellSize(ref).next
    }

    func moveStackCell(_ ref: SessionRef, by delta: Int) {
        guard case let .stack(refs) = activePage,
              let index = refs.firstIndex(of: ref) else { return }
        let target = index + delta
        guard refs.indices.contains(target) else { return }
        var newRefs = refs
        newRefs.swapAt(index, target)
        activePage = .stack(newRefs)
    }

    // ⌘⇧↩ — like maximizing/restoring a pane: grid cell → that session alone;
    // single session → its workspace grid.
    func toggleMaximize() {
        if DocumentSplitState.shared.handleMaximizeShortcut(
            previewFocused: FocusedPreview.tabID() != nil,
            paneVisible: activePage == nil && !PreviewStore.shared.tabs.isEmpty) {
            return
        }
        if case let .stack(refs) = activePage {
            guard let ref = FocusedTerminal.ref().flatMap({ refs.contains($0) ? $0 : nil })
                ?? refs.first else { return }
            // A local reference is not a remote one: opening it as `.session`
            // sent the Local workspace's alias to mosh, which then looked for a
            // host called "local".
            let item = sidebarItem(for: ref)
            if case .session = item {
                selectedSessions = [ref]
                selectionAnchor = ref
            } else {
                selectedSessions = []
                selectionAnchor = nil
            }
            selection = item
        } else if case let .session(alias, _) = selection {
            stackWorkspace(alias)
        } else if case .localSession = selection {
            stackWorkspace(Workspace.local.alias)
        }
    }

    /// The sidebar row a reference stands for. The Local workspace has its own
    /// kind of row, and mixing the two is what starts a remote client for a
    /// session that runs here.
    func sidebarItem(for ref: SessionRef) -> SidebarItem {
        guard ref.alias == Workspace.local.alias else {
            return .session(alias: ref.alias, name: ref.name)
        }
        let path = localSessions.first { $0.handle == ref.name }?.path ?? NSHomeDirectory()
        return .localSession(name: ref.name, path: path)
    }

    private static func stackCellKey(_ ref: SessionRef) -> String {
        "\(ref.alias)/\(ref.name)"
    }

    private static func loadStackCellSizes() -> [String: StackCellSize] {
        guard let data = UserDefaults.standard.data(forKey: "stackCellSizes"),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.compactMapValues { StackCellSize(rawValue: $0) }
    }

    private static func saveStackCellSizes(_ sizes: [String: StackCellSize]) {
        let raw = sizes.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: "stackCellSizes")
    }

    func setSidebarWidth(_ w: CGFloat) {
        sidebarWidth = DMPaneWidth.sidebar.clamp(w)
    }

    func setContextWidth(_ w: CGFloat) {
        contextWidth = DMPaneWidth.context.clamp(w)
    }

    func flattenedSessions() -> [SessionRef] {
        sidebarWorkspaces.filter { !$0.isLocal }.flatMap { ws in
            sessions(in: ws.alias).map { SessionRef(alias: ws.alias, name: $0.name) }
        }
    }

    private var sessionNavigationItems: [SidebarItem] {
        sidebarWorkspaces.flatMap { workspace -> [SidebarItem] in
            guard !workspace.isLocal else {
                return localSessions.map { SidebarItem.localSession(name: $0.handle, path: $0.path) }
            }
            return sessions(in: workspace.alias).map {
                SidebarItem.session(alias: workspace.alias, name: $0.name)
            }
        }
    }

    func moveToNextSession() {
        moveSession(by: 1)
    }

    func moveToPreviousSession() {
        moveSession(by: -1)
    }

    private func moveSession(by offset: Int) {
        let items = sessionNavigationItems
        guard !items.isEmpty else { return }
        let current = activePage == nil ? selection.flatMap(items.firstIndex) : nil
        let next: Int
        if let current {
            next = (current + offset + items.count) % items.count
        } else {
            next = offset > 0 ? 0 : items.count - 1
        }
        openSession(items[next])
    }

    func goBack() {
        while let destination = navigationHistory.back() {
            guard let resolved = resolved(destination) else { continue }
            restoreNavigation(resolved)
            return
        }
    }

    func goForward() {
        while let destination = navigationHistory.forward() {
            guard let resolved = resolved(destination) else { continue }
            restoreNavigation(resolved)
            return
        }
    }

    private var navigationDestination: NavigationDestination {
        if let activePage { return .page(activePage) }
        if let selection { return .session(selection) }
        return .home
    }

    private func recordNavigation() {
        guard !isRestoringNavigation else { return }
        navigationHistory.record(navigationDestination)
    }

    private func resolved(_ destination: NavigationDestination) -> NavigationDestination? {
        switch destination {
        case .home:
            return .home
        case let .session(item):
            return sessionNavigationItems.contains(item) ? destination : nil
        case let .page(.stack(refs)):
            let available = refs.filter { sessionNavigationItems.contains(sidebarItem(for: $0)) }
            return available.isEmpty ? nil : .page(.stack(available))
        case .page:
            return destination
        }
    }

    private func restoreNavigation(_ destination: NavigationDestination) {
        isRestoringNavigation = true
        defer { isRestoringNavigation = false }
        switch destination {
        case .home:
            selection = nil
            selectedSessions = []
            selectionAnchor = nil
            activePage = nil
        case let .session(item):
            openSession(item)
        case let .page(page):
            activePage = page
        }
    }

    private func openSession(_ item: SidebarItem) {
        switch item {
        case let .session(alias, name):
            let ref = SessionRef(alias: alias, name: name)
            selectedSessions = [ref]
            selectionAnchor = ref
        case .localSession:
            selectedSessions = []
            selectionAnchor = nil
        }
        selection = item
    }

    func clickSession(_ ref: SessionRef) {
        // A session on a machine whose host key ssh refused cannot open: the
        // click goes to the review instead of a terminal stuck on ssh's banner.
        if sessionProblems[ref.alias]?.isHostKeyRejected == true,
           let workspace = visibleWorkspaces.first(where: { $0.alias == ref.alias }),
           let machine = MachineReadinessStore.shared.machine(forWorkspace: workspace.name) {
            showHostKey(machine)
            return
        }
        // re-clicking the open session (no multi-select) goes back home
        if selection == .session(alias: ref.alias, name: ref.name), selectedSessions == [ref], activePage == nil {
            selection = nil
            selectedSessions = []
            selectionAnchor = nil
            return
        }
        selectedSessions = [ref]
        selectionAnchor = ref
        selection = .session(alias: ref.alias, name: ref.name)
    }

    func clickLocalSession(_ item: SidebarItem) {
        guard case let .localSession(name, _) = item else { return }
        if selection == item, activePage == nil {
            goHome()
        } else if name == Workspace.operatorSession {
            openOperatorSession()
        } else {
            selection = item
        }
    }

    func goHome() {
        selection = nil
        selectedSessions = []
        selectionAnchor = nil
        activePage = nil
    }

    func paletteItems() -> [PaletteItem] {
        sidebarWorkspaces.flatMap { ws -> [PaletteItem] in
            guard !ws.isLocal else {
                return localSessions.map { s in
                    PaletteItem(
                        id: "local/\(s.handle)",
                        title: s.name,
                        subtitle: Workspace.local.name,
                        target: .localSession(name: s.handle, path: s.path),
                        badges: badges(for: s)
                    )
                }
            }
            return sessions(in: ws.alias).map { s in
                PaletteItem(
                    id: "\(ws.alias)/\(s.name)",
                    title: s.name,
                    subtitle: ws.name,
                    target: .session(alias: ws.alias, name: s.name),
                    badges: badges(for: s)
                )
            }
        }
    }

    func openPalette(_ item: PaletteItem) {
        jump(to: item.target)
        showCommandPalette = false
    }

    func jump(to item: SidebarItem) {
        if case let .localSession(name, _) = item, name == Workspace.operatorSession {
            openOperatorSession()
            return
        }
        selection = item
        if case let .session(alias, name) = item {
            let ref = SessionRef(alias: alias, name: name)
            selectedSessions = [ref]
            selectionAnchor = ref
        }
    }

    func openSettings(_ section: SettingsSection) {
        requestedSettingsSection = section
        activePage = .setup
    }

    /// "Packages on this machine": Settings → Packages, filtered to it.
    func openPackages(machine: String) {
        requestedPackagesMachine = machine
        openSettings(.packages)
    }

    /// "Packages for this workspace": Settings → Packages, filtered to it.
    func openPackages(workspace: String) {
        requestedPackagesWorkspace = workspace
        openSettings(.packages)
    }

    /// A switch in Settings → Workspaces takes effect at once, with no Save:
    /// only the hidden list is written, so nothing else typed in Settings is.
    func setHiddenWorkspaces(_ hidden: [String], in store: SettingsStore = .shared) {
        guard var current = store.settings, current.hiddenWorkspaces != hidden else { return }
        current.hiddenWorkspaces = hidden
        store.settings = current
        settings?.hiddenWorkspaces = hidden
        // Before reloading: the panes of a workspace just turned off have to
        // go now, and the reload must not bring their poll back.
        applyHiddenWorkspaces()
        loadWorkspaces()
    }

    /// The wizard opened from Settings → Machines goes back there, so Settings
    /// and the wizard read as one place; from anywhere else it just closes.
    private var addMachineOpenedFromSettings = false

    func closeAddMachine() {
        guard activePage == .addMachine else { return }
        if addMachineOpenedFromSettings {
            openSettings(.machines)
        } else {
            activePage = nil
        }
    }

    func requestPublish(workspace: String) {
        pendingPublishWorkspace = workspace
    }

    /// Settings → Workspaces opens on its New workspace form
    /// (`WorkspacesSettingsView` takes the request).
    func requestNewWorkspace() {
        pendingNewWorkspace = true
        openSettings(.workspaces)
    }

    func requestAddSubdomain() {
        activePage = .subdomains
        pendingAddSubdomain = true
    }

    /// Opens the host key review over the current screen, which stays as it is.
    func showHostKey(_ machine: String) {
        hostKeyMachine = machine
    }

    func closeHostKey() {
        hostKeyMachine = nil
    }

    /// The terminal a command such as "Send file" acts on: the selected
    /// session, or the focused cell of a stack.
    var currentTerminalKind: TerminalKind? {
        switch activePage {
        case nil:
            return selection?.terminalKind
        case let .stack(refs):
            let ref = FocusedTerminal.ref().flatMap { refs.contains($0) ? $0 : nil } ?? refs.first
            return ref.map { sidebarItem(for: $0).terminalKind }
        default:
            return nil
        }
    }

    var currentWorkspaceAlias: String? {
        switch currentTerminalKind {
        case let .remote(alias, _): return alias
        case .local: return Workspace.local.alias
        case nil: return nil
        }
    }

    func cmdClickSession(_ ref: SessionRef) {
        if selectedSessions.contains(ref) {
            selectedSessions.remove(ref)
        } else {
            selectedSessions.insert(ref)
        }
        selectionAnchor = ref
    }

    func shiftClickSession(_ ref: SessionRef) {
        let flattened = flattenedSessions()
        let anchor = selectionAnchor ?? ref
        guard let anchorIndex = flattened.firstIndex(of: anchor),
              let refIndex = flattened.firstIndex(of: ref) else {
            selectedSessions = [ref]
            return
        }
        let range = anchorIndex <= refIndex ? anchorIndex...refIndex : refIndex...anchorIndex
        selectedSessions = Set(flattened[range])
    }

    @discardableResult
    func beginTask(label: String, total: Int, showsCount: Bool = true) -> UUID {
        let id = UUID()
        activeTasks.append(
            BGTask(id: id, label: label, completed: 0, total: total, showsCount: showsCount))
        return id
    }

    private func bumpTask(_ id: UUID) {
        if let i = activeTasks.firstIndex(where: { $0.id == id }) {
            activeTasks[i].completed += 1
        }
    }

    /// Progress that arrives as a running total, such as bytes written.
    func setTask(_ id: UUID, completed: Int) {
        guard let i = activeTasks.firstIndex(where: { $0.id == id }) else { return }
        guard activeTasks[i].completed != completed else { return }
        activeTasks[i].completed = completed
    }

    /// Drops the card at once, for a job that finished too fast to be worth a
    /// tick of "done": the 60s sweep would otherwise blink a card every minute.
    func dropTask(_ id: UUID) {
        activeTasks.removeAll { $0.id == id }
    }

    func flashToast(_ label: String) {
        finishTask(beginTask(label: label, total: 1))
    }

    func announceCopiedColor(_ hex: String) {
        flashToast("Copied \(hex)")
    }

    func finishTask(_ id: UUID) {
        if let i = activeTasks.firstIndex(where: { $0.id == id }) {
            activeTasks[i].completed = activeTasks[i].total
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.activeTasks.removeAll { $0.id == id }
        }
    }

    func deleteSessions(_ refs: [SessionRef]) {
        pendingBulkDelete = nil
        guard !refs.isEmpty else { return }
        updateSidebarOrder { order in
            for ref in refs { order.removeSession(ref.name, in: ref.alias) }
        }
        let taskId = beginTask(label: "Deleting sessions", total: refs.count)
        Task.detached { [store] in
            for ref in refs {
                _ = try? store.run(alias: ref.alias, command: RemoteCommands.killSession(name: ref.name))
                await MainActor.run { self.bumpTask(taskId) }
            }
            let affectedAliases = Set(refs.map(\.alias))
            await MainActor.run {
                for alias in affectedAliases { self.refresh(alias: alias) }
                for ref in refs {
                    self.selectedSessions.remove(ref)
                    TerminalRegistry.shared.close(alias: ref.alias, session: ref.name)
                    PreviewStore.shared.closeSession(ref)
                    let item = SidebarItem.session(alias: ref.alias, name: ref.name)
                    if self.selection == item {
                        self.selection = nil
                    }
                }
                self.finishTask(taskId)
            }
        }
    }

    func renameSession(alias: String, old: String, new: String) {
        let clean = new.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { pendingRename = nil; return }
        let range = NSRange(clean.startIndex..., in: clean)
        guard Self.validSessionName.firstMatch(in: clean, range: range) != nil else {
            pendingRename = nil
            return
        }
        pendingRename = nil
        updateSidebarOrder { $0.renameSession(old, to: clean, in: alias) }
        renamesInFlight[SessionRef(alias: alias, name: clean)] = Date()
        let taskId = beginTask(label: "Renaming \(old)", total: 1)
        Task.detached { [store] in
            _ = try? store.run(alias: alias, command: RemoteCommands.rename(session: old, to: clean))
            await MainActor.run {
                self.bumpTask(taskId)
                self.refresh(alias: alias)
                // The old client is still attached to the renamed tmux session;
                // drop it so the new name mounts as the only client.
                TerminalRegistry.shared.close(alias: alias, session: old)
                PreviewStore.shared.moveSession(
                    from: SessionRef(alias: alias, name: old), to: SessionRef(alias: alias, name: clean))
                let oldItem = SidebarItem.session(alias: alias, name: old)
                if self.selection == oldItem {
                    self.selection = .session(alias: alias, name: clean)
                }
                self.finishTask(taskId)
            }
        }
    }

    func deleteSession(alias: String, name: String) {
        updateSidebarOrder { $0.removeSession(name, in: alias) }
        let taskId = beginTask(label: "Deleting \(name)", total: 1)
        Task.detached { [store] in
            _ = try? store.run(alias: alias, command: RemoteCommands.killSession(name: name))
            await MainActor.run {
                self.bumpTask(taskId)
                self.refresh(alias: alias)
                TerminalRegistry.shared.close(alias: alias, session: name)
                PreviewStore.shared.closeSession(SessionRef(alias: alias, name: name))
                let item = SidebarItem.session(alias: alias, name: name)
                if self.selection == item {
                    self.selection = nil
                }
                self.finishTask(taskId)
            }
        }
    }

    private static let validSessionName = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]+$")

    /// Remembered so the next session starts where the last one did.
    @Published var newSessionDirectory: String =
        UserDefaults.standard.string(forKey: "newSessionDirectory") ?? "~/dev" {
        didSet { UserDefaults.standard.set(newSessionDirectory, forKey: "newSessionDirectory") }
    }

    func confirmNewSession(alias: String, name: String, directory: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { pendingNewSessionAlias = nil; return }
        let range = NSRange(clean.startIndex..., in: clean)
        guard Self.validSessionName.firstMatch(in: clean, range: range) != nil else {
            pendingNewSessionAlias = nil
            return
        }
        newSessionDirectory = directory
        pendingNewSessionAlias = nil
        createRemoteSession(alias: alias, name: clean, directory: directory)
    }

    private func createRemoteSession(
        alias: String, name: String, directory: String, taskID: UUID? = nil, startup: SessionStartup = .configured
    ) {
        // Created here rather than left to the terminal's own `new-session -A`,
        // because only a session created up front can be told which directory to
        // start in, and harnesses resolve project files from that location.
        let store = self.store
        let startup = startupLine(startup, for: .remote(alias: alias, session: name))
        let sender = sessionCommandSender
        Task.detached {
            _ = try? store.run(
                alias: alias, command: RemoteCommands.createSession(name: name, directory: directory))
            if let startup {
                try? sender.send(startup, into: .remote(alias: alias, session: name))
            }
            await MainActor.run {
                self.selection = .session(alias: alias, name: name)
                if let taskID {
                    self.bumpTask(taskID)
                    self.finishTask(taskID)
                }
            }
        }
        // With no global poll, a single refresh can race the create, so re-poll
        // a few times until the new session shows up in the sidebar.
        for delay in [1.5, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.refresh(alias: alias) }
        }
    }

    enum LaunchRoute: Equatable {
        case onboarding
        case home
    }

    static let onboardingSkippedKey = "onboardingSkipped"

    /// Home needs saved settings, and the CLI unless the person chose to go
    /// without it. Anything else is the setup flow, never Settings, which
    /// used to greet a first run with a form to fill in.
    static func launchRoute(cliFound: Bool, isConfigured: Bool, skipped: Bool) -> LaunchRoute {
        isConfigured && (cliFound || skipped) ? .home : .onboarding
    }

    var onboardingSkipped: Bool { defaults.bool(forKey: Self.onboardingSkippedKey) }

    /// Runs at launch. Onboarding owns the window while it is due, and
    /// nothing below it starts; otherwise the workspaces load.
    func checkCLIAndProceed(isConfigured: Bool) {
        if DemoMode.isActive {
            seedDemoState()
            return
        }
        cliMissing = !cliAvailabilityCheck()
        switch Self.launchRoute(cliFound: !cliMissing, isConfigured: isConfigured, skipped: onboardingSkipped) {
        case .onboarding:
            showsOnboarding = true
        case .home:
            showsOnboarding = false
            loadWorkspaces()
        }
    }

    /// Reads the CLI again, off the main thread: Settings asks each time it
    /// opens, so a CLI installed after launch is picked up.
    @discardableResult
    func refreshDetected() async -> CLIDetectedSettings {
        guard !DemoMode.isActive else { return detected }
        let detect = detectSettings
        let next = await Task.detached { detect() }.value
        if detected != next { detected = next }
        return next
    }

    /// "Start using Devmachine": straight into Home, with no restart and no
    /// stop at Settings. What the CLI reports fills the empty Connection
    /// fields and is saved, so Settings opens already valid.
    func completeOnboarding(saving store: SettingsStore) async {
        await leaveOnboarding(saving: store)
    }

    /// "Skip for now": Home with local sessions only. Remembered, so the next
    /// launch does not ask again; Settings can open the setup later.
    func skipOnboarding(saving store: SettingsStore) async {
        defaults.set(true, forKey: Self.onboardingSkippedKey)
        await leaveOnboarding(saving: store)
    }

    /// Back to the setup flow from Settings: the skip is forgotten.
    func openOnboarding() {
        defaults.removeObject(forKey: Self.onboardingSkippedKey)
        activePage = nil
        showsOnboarding = true
    }

    /// Home's machine cards and the machine lists read again when
    /// onboarding ends: the setup may have just written the first machine.
    var onLeftOnboarding: (() -> Void)?

    /// One read of the CLI, off the main thread, handed to the workspace
    /// load instead of a second one on it.
    private func leaveOnboarding(saving store: SettingsStore) async {
        let detected = await refreshDetected()
        let check = cliAvailabilityCheck
        let cliFound = await Task.detached { check() }.value
        let next = detected.filling(store.settings ?? .empty)
        if store.settings != next { store.settings = next }
        settings = next
        cliMissing = !cliFound
        activePage = nil
        showsOnboarding = false
        loadWorkspaces(detected: detected)
        onLeftOnboarding?()
    }

    /// `DEVMACHINE_DEMO=1`: skips the CLI gate, Setup, and every ssh/CLI call
    /// `loadWorkspaces()` would make, and instead seeds the sidebar directly
    /// from `DemoData`. Every terminal pane renders a static transcript
    /// (`TerminalRegistry.start` short-circuits the same way) instead of
    /// spawning mosh/ssh/zmx.
    private func seedDemoState() {
        cliMissing = false
        showsOnboarding = false
        settings = .empty
        hasCaddyMachine = true
        activePage = nil
        guard !DemoMode.holdsLoading else { return }
        workspaces = DemoData.workspaces
        sessionsByAlias = DemoData.sessionsByAlias
        hasLoadedWorkspaces = true
        answeredAliases = Set(DemoData.workspaces.map(\.alias))
        let socketDirectory = Zmx.socketDirectory()
        localSessionHarnesses = Dictionary(uniqueKeysWithValues: DemoData.localSessionHarnesses.map { name, harnesses in
            (Zmx.sessionName(from: name, socketDirectory: socketDirectory), harnesses)
        })
        // `localSessions` (below) reads `DemoData.localSessions` directly in
        // demo mode; `addedLocalSessions` is left untouched so nothing here
        // is ever written to `UserDefaults`.
    }

    /// The loading demo's second stage: the workspace list is in, and only
    /// `answered` has its sessions; every other workspace is still waiting.
    func seedDemoWorkspacesAwaitingSessions(answered alias: String) {
        guard DemoMode.holdsLoading else { return }
        workspaces = DemoData.workspaces
        sessionsByAlias = DemoData.sessionsByAlias.filter { $0.key == alias }
        answeredAliases = [alias]
        hasLoadedWorkspaces = true
    }

    private func forgetOrderOfRemovedWorkspaces(present: [Workspace]) {
        updateSidebarOrder { $0.keepWorkspaces(present.map(\.alias) + [Workspace.local.alias]) }
    }

    func loadWorkspaces(detected known: CLIDetectedSettings? = nil) {
        guard let settings else { return }
        let detected = known ?? detectSettings()
        if self.detected != detected { self.detected = detected }
        var settingsWithAliases = settings
        settingsWithAliases.workspaceAliases = detected.workspaceAliases
        self.settings = settingsWithAliases
        let loaded = try? services.workspaceSource.workspaces(
            resolveAlias: { settingsWithAliases.hostAlias(forWorkspace: $0) })
        workspaces = loaded ?? []
        // Only a list that was read can say a workspace is gone; a failed read
        // must not wipe the order.
        if let loaded { forgetOrderOfRemovedWorkspaces(present: loaded) }
        hasLoadedWorkspaces = true
        showCachedSessions()
        refreshAll()
        checkPackageGate()
        // A slow sweep of every workspace so an offline one comes back on its
        // own; the 5s timer only follows the selected one.
        sweepTimer?.invalidate()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        scanLocalSessions()
        localScanTimer?.invalidate()
        localScanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanLocalSessions() }
        }
    }

    #if DEBUG
    func seedDemoDetected(_ value: CLIDetectedSettings) {
        detected = value
    }

    func seedDemoSessionProblem(_ problem: SessionProblem?, alias: String) {
        sessionProblems[alias] = problem
        if problem != nil { sessionsByAlias[alias] = [] }
    }
    #endif

    /// The CLI's configuration changed while the app was open: a machine or
    /// workspace added, an alias written, a sync finished. The workspace list
    /// and aliases are read again, off the main thread, and a new workspace is
    /// polled at once and again after every change until it logs in.
    func reloadConfiguration() {
        guard let settings, hasLoadedWorkspaces, !DemoMode.isActive else { return }
        let source = services.workspaceSource
        let detect = detectSettings
        Task {
            let detected = await Task.detached { detect() }.value
            var settingsWithAliases = self.settings ?? settings
            settingsWithAliases.workspaceAliases = detected.workspaceAliases
            let resolved = settingsWithAliases
            let next = await Task.detached {
                (try? source.workspaces(resolveAlias: { resolved.hostAlias(forWorkspace: $0) })) ?? []
            }.value
            if self.detected != detected { self.detected = detected }
            if self.settings != settingsWithAliases { self.settings = settingsWithAliases }
            if !next.isEmpty, next != self.workspaces {
                let known = Set(self.workspaces.map(\.alias))
                self.workspaces = next
                self.forgetOrderOfRemovedWorkspaces(present: next)
                for workspace in next where !known.contains(workspace.alias) {
                    self.awaitingFirstLogin.insert(workspace.alias)
                    self.sessionProblems[workspace.alias] = nil
                }
                self.awaitingFirstLogin.formIntersection(next.map(\.alias))
            }
            for alias in self.awaitingFirstLogin {
                if self.sessionProblems[alias]?.isAwaitingSync == true { self.sessionProblems[alias] = nil }
                self.refresh(alias: alias)
            }
        }
        Task {
            let hasCaddy = await Task.detached {
                CaddyAvailabilityChecker.check(cli: { try DevmachineCLI.resolve() })
            }.value
            if let hasCaddy { self.hasCaddyMachine = hasCaddy }
        }
    }

    /// A machine was just prepared: its workspaces are listed again now
    /// rather than at the next sweep.
    /// The machine's host key was trusted, or already matched: its
    /// workspaces stop showing the refusal and are read again at once.
    func hostKeyResolved(onMachine machine: String) {
        let readiness = MachineReadinessStore.shared
        for workspace in visibleWorkspaces where readiness.machine(forWorkspace: workspace.name) == machine {
            if sessionProblems[workspace.alias]?.isHostKeyRejected == true {
                sessionProblems[workspace.alias] = nil
            }
        }
        refreshWorkspaces(onMachine: machine)
    }

    /// Clears a refused host key for one workspace and reads it again: the
    /// sidebar's Try again, when no machine card covers it.
    func retry(alias: String) {
        if sessionProblems[alias]?.isHostKeyRejected == true || sessionProblems[alias]?.isAwaitingSync == true {
            sessionProblems[alias] = nil
        }
        refresh(alias: alias)
    }

    func refreshWorkspaces(onMachine machine: String) {
        let readiness = MachineReadinessStore.shared
        for workspace in visibleWorkspaces where readiness.machine(forWorkspace: workspace.name) == machine {
            refresh(alias: workspace.alias)
        }
        syncContext()
    }

    /// The last session list each workspace answered, drawn at launch so the
    /// sidebar is full before the first sweep. The sweep replaces it within
    /// seconds, one workspace at a time.
    private func showCachedSessions() {
        for workspace in visibleWorkspaces where sessionsByAlias[workspace.alias] == nil {
            guard let cached = cache.cached(MachineDataKeys.sessions(workspace.alias)) else { continue }
            sessionsByAlias[workspace.alias] = cached.value
            markAnswered(workspace.alias)
        }
    }

    /// Runs at launch (`loadWorkspaces`) and whenever the CLI's
    /// configuration changes. Both checks fail open: a read that itself fails
    /// leaves things as they were rather than blocking the app on a flaky CLI.
    func checkPackageGate() {
        MachineReadinessStore.shared.requestCheck()
        Task {
            let hasCaddy = await Task.detached {
                CaddyAvailabilityChecker.check(cli: { try DevmachineCLI.resolve() })
            }.value
            if let hasCaddy { self.hasCaddyMachine = hasCaddy }
        }
    }

    // One ssh at a time, and the sweep stops at the first ssh-level failure:
    // nine parallel auths against a locked agent are nine denied logins in
    // one second, which is a fail2ban ban of this Mac.
    func refreshAll() {
        guard !DemoMode.isActive, Date() >= pollPausedUntil, !sweepInFlight else { return }
        let targets = visibleWorkspaces.filter {
            !refreshingAliases.contains($0.alias) && sessionProblems[$0.alias]?.isAwaitingSync != true
        }
        guard !targets.isEmpty else { return }
        sweepInFlight = true
        let sweepTask = beginTask(label: "Connecting workspaces…", total: targets.count)
        sweepTaskID = sweepTask
        for ws in targets { refreshingAliases.insert(ws.alias) }
        let source = services.sessionSource
        let settings = settings ?? .empty
        Task.detached {
            var remaining = targets[...]
            var stopped: SSHFailure?
            while let ws = remaining.first {
                remaining = remaining.dropFirst()
                let outcome = Result {
                    try source.sessions(for: ws, settings: settings)
                }
                let stop = await MainActor.run { () -> SSHFailure? in
                    let stop = self.apply(outcome, alias: ws.alias)
                    self.bumpTask(sweepTask)
                    return stop
                }
                if let stop { stopped = stop; break }
            }
            // The aliases the stopped sweep never reached share the same host,
            // so an unreachable host takes them with it. A refused login says
            // nothing about the host, so it leaves them as they were.
            let unreached = Array(remaining)
            await MainActor.run {
                if stopped == .unreachable {
                    for ws in unreached where !self.offlineAliases.contains(ws.alias) {
                        self.offlineAliases.insert(ws.alias)
                    }
                    for ws in unreached where self.sessionProblems[ws.alias] == nil {
                        self.sessionProblems[ws.alias] = .unreachable(
                            detail: "Not asked: an earlier workspace on the same host could not be reached.")
                    }
                }
                for ws in unreached { self.markAnswered(ws.alias) }
                for ws in targets { self.refreshingAliases.remove(ws.alias) }
                self.sweepInFlight = false
                self.sweepTaskID = nil
                self.dropTask(sweepTask)
            }
        }
    }

    func refresh(alias: String) {
        guard !DemoMode.isActive, Date() >= pollPausedUntil,
              let ws = visibleWorkspaces.first(where: { $0.alias == alias }) else { return }
        // A refused host key fails the same way until someone reviews it: the
        // 5s selection poll leaves it to the 60s sweep instead of a handshake
        // every tick. Retry and a trust clear the problem first.
        guard sessionProblems[alias]?.isHostKeyRejected != true else { return }
        // Each try before the sync is one more denied login toward a ban:
        // only a configuration change or Try again asks again.
        guard sessionProblems[alias]?.isAwaitingSync != true else { return }
        // A tick that arrives while the previous ssh for this alias is still
        // running is dropped: a slow host would otherwise stack one blocked
        // process per 5s tick.
        guard !refreshingAliases.contains(alias) else { return }
        refreshingAliases.insert(alias)
        let source = services.sessionSource
        let settings = settings ?? .empty
        Task.detached {
            let outcome = Result {
                try source.sessions(for: ws, settings: settings)
            }
            await MainActor.run {
                self.refreshingAliases.remove(alias)
                _ = self.apply(outcome, alias: alias)
            }
        }
    }

    // Returns the failure that must pause polling: the host or the ssh agent is
    // down. Nil means the sweep goes on.
    private func apply(_ outcome: Result<[TmuxSession], Error>, alias: String) -> SSHFailure? {
        markAnswered(alias)
        switch outcome {
        case .success(let result):
            // Assign only on a real change: every write to a @Published
            // re-renders the whole tree, and the 5s poll usually returns
            // exactly what is already on screen.
            if sessionsByAlias[alias] != result {
                sessionsByAlias[alias] = result
                dropMissingSessions(alias: alias, present: result)
            }
            cache.put(MachineDataKeys.sessions(alias), result)
            awaitingFirstLogin.remove(alias)
            if offlineAliases.contains(alias) {
                offlineAliases.remove(alias)
            }
            if sessionProblems[alias] != nil { sessionProblems[alias] = nil }
            syncContext()
            return nil
        case .failure(let error):
            let failure = (error as? SessionStoreError)?.failure
            // A refused login on a workspace that never logged in is its
            // missing account, not a locked agent: it pauses nothing.
            if failure == .authDenied, awaitingFirstLogin.contains(alias) {
                let problem = SessionProblem.awaitingSync(detail: (error as? SessionStoreError)?.stderr ?? "")
                if sessionProblems[alias] != problem { sessionProblems[alias] = problem }
                offlineAliases.remove(alias)
                syncContext()
                return nil
            }
            let problem = SessionProblem(error)
            if sessionProblems[alias] != problem { sessionProblems[alias] = problem }
            if (error as? SessionListError)?.problem == .tmuxMissing {
                awaitingFirstLogin.remove(alias)
            }
            // One workspace's own problem (no alias, no tmux): the host may be
            // fine, and every other workspace on it still polls.
            if error is SessionListError {
                offlineAliases.remove(alias)
                syncContext()
                return nil
            }
            // The host answered with a key this Mac does not trust. No login
            // was tried, so nothing counts toward a ban, and other machines
            // have their own keys: the sweep goes on, and the machine's host
            // key card says what to do.
            if failure == .hostKeyRejected {
                offlineAliases.remove(alias)
                syncContext()
                return nil
            }
            // Red means the host does not answer. A login this Mac cannot sign
            // — a locked agent after waking — says nothing about the host, and
            // the sessions on it keep running: the bar already says polling is
            // paused, and a red dot on top of that is a lie that stays on
            // screen until the next successful sweep.
            if failure == .authDenied {
                offlineAliases.remove(alias)
            } else if !offlineAliases.contains(alias) {
                offlineAliases.insert(alias)
            }
            syncContext()
            guard let failure else { return nil }
            pausePolling(after: failure)
            return failure
        }
    }

    /// True while a failure is holding the sweep back.
    var isPollingPaused: Bool { Date() < pollPausedUntil }

    /// True while the sweep logs into each workspace in turn.
    var isSweeping: Bool { sweepInFlight }

    /// The machine a workspace alias lives on, as the configuration says.
    func machine(forAlias alias: String) -> String? {
        guard let workspace = workspaces.first(where: { $0.alias == alias }) else { return nil }
        return MachineReadinessStore.shared.machine(forWorkspace: workspace.name)
    }

    /// An ssh made outside the sweep (the copy mode check) failed the way
    /// that pauses polling: the same backoff applies, so nothing else logs
    /// in again at once.
    func noteSSHFailure(_ failure: SSHFailure) {
        guard failure != .hostKeyRejected else { return }
        pausePolling(after: failure)
    }

    /// Sleeping made every ssh fail at once, which paused the sweep and turned
    /// the whole sidebar red. Waking is the evidence that the pause no longer
    /// applies, so it is lifted and the sweep runs at once instead of leaving
    /// the sidebar wrong for up to two minutes.
    func resumePollingAfterWake() {
        pollPausedUntil = .distantPast
        sweepInFlight = false
        refreshingAliases.removeAll()
        refreshAll()
    }

    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared?.resumePollingAfterWake() }
            }
        }
    }

    private func pausePolling(after failure: SSHFailure) {
        let seconds: TimeInterval = failure == .authDenied ? 300 : 60
        pollPausedUntil = Date().addingTimeInterval(seconds)
        let label = failure == .authDenied
            ? "SSH auth denied — polling paused 5 min (unlock the ssh agent)"
            : "Host unreachable — polling paused 1 min"
        let id = beginTask(label: label, total: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.finishTask(id) }
    }

    /// Provider context polls only while its tab is actually on screen.
    func syncContext() {
        guard showsContextPanel, !contextCollapsed, contextTab == .context,
              let target = selectedSessionTarget else {
            context.stop()
            updateSelectionPoll()
            return
        }
        context.start(target, harnesses: selectedSessionHarnesses, settings: settings ?? .empty)
        updateSelectionPoll()
    }

    var showsContextPanel: Bool { selection != nil && activePage == nil }

    /// Context, Files and Git share the selected session's current location.
    var selectedSessionTarget: CommandTarget? {
        switch selection {
        case let .session(alias, name):
            return .remote(alias: alias, session: name)
        case let .localSession(name, path):
            let session = localSessions.first { $0.handle == name }
            return .local(session: name, path: session.flatMap(localWorkingDirectory) ?? path)
        case nil:
            return nil
        }
    }

    private var selectedSessionHarnesses: Set<HarnessID> {
        switch selection {
        case let .session(alias, name):
            return sessionsByAlias[alias]?.first { $0.name == name }?.harnesses ?? []
        case let .localSession(name, _):
            let multiplexerName = Zmx.sessionName(from: name, socketDirectory: Zmx.socketDirectory())
            return localSessionHarnesses[multiplexerName] ?? []
        case nil:
            return []
        }
    }

    /// Where the Preview tab's ports live: the selected session's workspace,
    /// or this Mac for a local session.
    var selectedPreviewPlace: PreviewPlace? {
        switch selection {
        case let .session(alias, _):
            return .workspace((settings ?? .empty).workspaceName(forAlias: alias))
        case .localSession:
            return .thisMac
        case nil:
            return nil
        }
    }

    /// ⌘K "Open preview…": the Preview tab, with its field ready to type in.
    @Published var pendingPreviewField = false

    func requestPreviewField() {
        contextCollapsed = false
        contextTab = .preview
        pendingPreviewField = true
    }

    /// Asked for by whoever opens a file, so the tree follows it. The panel
    /// owns the tree, so it listens for this instead of being called directly.
    @Published var revealInTree: String?

    func openedFile(at path: String) {
        contextTab = .files
        revealInTree = path
    }

    /// Where a panel or the search field reads from, for whatever is selected.
    /// The one place that turns a sidebar row into a target.
    func commandTarget(for item: SidebarItem?) -> CommandTarget? {
        switch item {
        case let .session(alias, name):
            return .remote(alias: alias, session: name)
        case let .localSession(name, path):
            let session = localSessions.first { $0.handle == name }
            return .local(
                session: name, path: session.flatMap(localWorkingDirectory) ?? path)
        case nil:
            return nil
        }
    }

    // 5s poll of only the selected session's workspace; no session selected, no poll.
    private func updateSelectionPoll() {
        guard case let .session(alias, _) = selection else {
            selectionPollTimer?.invalidate()
            selectionPollTimer = nil
            selectionPollAlias = nil
            return
        }
        guard selectionPollAlias != alias || selectionPollTimer == nil else { return }

        selectionPollAlias = alias
        selectionPollTimer?.invalidate()
        selectionPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(alias: alias) }
        }
    }
}
