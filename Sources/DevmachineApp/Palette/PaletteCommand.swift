import Foundation
import DevmachineCore

/// The group a command is listed under. The order here is the order of the
/// groups when nothing else decides it.
enum PaletteCategory: Int, CaseIterable, Comparable {
    case recent, goTo, session, chats, workspace, machine, settings, action

    var title: String {
        switch self {
        case .recent: return "Recent"
        case .goTo: return "Go to"
        case .session: return "Session"
        case .chats: return "Chats"
        case .workspace: return "Workspace"
        case .machine: return "Machine"
        case .settings: return "Settings"
        case .action: return "Action"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a command does, as data: the registry builds these and
/// `PaletteDispatcher` is the one place that turns them into app calls.
enum PaletteAction: Equatable {
    case goHome
    case showPage(AppPage)
    case openSettings(SettingsSection)
    case runHealthCheck
    case openSession(SidebarItem)
    case newSession(alias: String, choice: SessionLaunchChoice)
    case runSavedCommand(alias: String, command: String)
    case customCommand(alias: String)
    case newNamedSession(alias: String)
    case newQuickSession
    case publishPort(workspace: String)
    case newWorkspace
    case openFiles(alias: String)
    case openSessionGrid(alias: String)
    case revealInFinder(path: String)
    case stats(machine: String)
    case hostKey(machine: String)
    case subdomains(machine: String)
    case addSubdomain(machine: String?)
    case addWidget
    case sendFile(TerminalKind)
    case endSession
    case shareSession(SessionRef)
    case findFile
    case refresh
    case toggleSidebar
    case toggleContext
    case showShortcuts
    case back
    case forward
    case previousSession
    case nextSession
    case maximizePane
    case openURL(URL)
    case checkForUpdates
    case logs(LogAction)
    case preview(PreviewRequest)
    case openPreviewField
    case pickColor
    case newChat(place: ChatPlace?, harness: HarnessID?)
    case openChat(id: String)
    case showChats
    case showCode
    case openSchema
    case quit
}

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let category: PaletteCategory
    let systemImage: String
    var shortcut: String? = nil
    var keywords: [String] = []
    var badges: [HarnessBadgePresentation] = []
    var badgeText: String? = nil
    var harness: HarnessID? = nil
    let action: PaletteAction
}

/// What the registry needs to know about the app right now, as plain values,
/// so the list of commands can be built and tested without a running app.
struct PaletteContext {
    var workspaces: [Workspace] = []
    var sessions: [PaletteItem] = []
    var localSessions: [LocalSession] = []
    /// What a remote workspace's new session may start.
    var launchOptions: [HarnessLaunchOption] = [.terminal]
    /// What a session on this Mac may start: a harness needs its CLI here.
    /// Nil means the same as `launchOptions`.
    var localLaunchOptions: [HarnessLaunchOption]?
    var savedCommands: [String: [String]] = [:]
    var machines: [String] = []
    var hasCaddyMachine = false
    var subdomainsMachine: String?
    var currentTerminal: TerminalKind?
    var endableSession: SidebarItem?
    var currentWorkspaceAlias: String?
    var activePage: AppPage?
    var cliUpdate: CLIUpdateNotice?
    var previewTargets: [PalettePreviewGroup] = []
    var chats: [ChatRecord] = []
    var chatSettings = ChatSettings.default
    var chatConfig = ChatCLIConfig()
    var chatWorkspaces: [String] = []
    var cliLogExists = false
    var historyExists = false

    var currentWorkspace: Workspace? {
        guard let alias = currentWorkspaceAlias else { return nil }
        if alias == Workspace.local.alias { return .local }
        return workspaces.first { $0.alias == alias }
    }
}

/// What one workspace, or this Mac, can preview: the Preview tab's last list.
struct PalettePreviewGroup {
    let place: PreviewPlace
    let targets: [PreviewTarget]
}
