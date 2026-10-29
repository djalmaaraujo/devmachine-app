import AppKit
import DevmachineCore

@MainActor
protocol PaletteStatsControlling: AnyObject {
    func select(_ name: String)
    func refresh()
}

@MainActor
protocol PaletteSitesControlling: AnyObject {
    func prefer(machine: String)
    func refresh()
}

@MainActor
protocol PaletteHealthChecking: AnyObject {
    func run()
}

@MainActor
protocol PaletteSavedCommandRecording: AnyObject {
    @discardableResult
    func record(_ raw: String, for alias: String) -> String?
}

@MainActor
protocol PaletteUpdateChecking: AnyObject {
    func checkNow()
}

extension UpdateController: PaletteUpdateChecking {}

@MainActor
protocol PaletteLogsHandling {
    func perform(_ action: LogAction)
}

@MainActor
struct LiveLogActions: PaletteLogsHandling {
    func perform(_ action: LogAction) {
        Task { await LogActionRunner().perform(action) }
    }
}

/// What reaches outside the app's own state: windows, Finder, the browser.
@MainActor
protocol PaletteSystem {
    func openFilesWindow(alias: String)
    func reveal(path: String)
    func open(_ url: URL)
    func quit()
    func chooseFileAndSend(to kind: TerminalKind)
    func pickScreenColor(onCopy: @escaping @MainActor (String) -> Void)
}

@MainActor
protocol PalettePreviewOpening: AnyObject {
    func open(_ request: PreviewRequest, inverted: Bool)
}

extension PreviewStore: PalettePreviewOpening {}
extension StatsStore: PaletteStatsControlling {}
extension CaddyStore: PaletteSitesControlling {}
extension HealthCheckStore: PaletteHealthChecking {}
extension RecentCommandStore: PaletteSavedCommandRecording {}

/// Runs a palette command through the same model calls the sidebar, the
/// menus and the pages use, so the palette has no navigation of its own.
@MainActor
struct PaletteDispatcher {
    let model: AppModel
    let stats: any PaletteStatsControlling
    let sites: any PaletteSitesControlling
    let health: any PaletteHealthChecking
    let savedCommands: any PaletteSavedCommandRecording
    let updates: any PaletteUpdateChecking
    let recents: PaletteRecentsStore
    let system: any PaletteSystem
    var previews: any PalettePreviewOpening = PreviewStore.shared
    var chats: ChatStore = .shared
    var logs: any PaletteLogsHandling = LiveLogActions()

    func perform(_ command: PaletteCommand) {
        model.showCommandPalette = false
        recents.record(command.id)
        perform(command.action)
    }

    private func perform(_ action: PaletteAction) {
        switch action {
        case .goHome: model.goHome()
        case let .showPage(page): model.showPage(page)
        case let .openSettings(section): model.openSettings(section)
        case .runHealthCheck:
            health.run()
            model.openSettings(.healthCheck)
        case let .openSession(item): model.jump(to: item)
        case let .newSession(alias, choice): model.openSession(in: alias, startup: .program(choice))
        case let .runSavedCommand(alias, command):
            savedCommands.record(command, for: alias)
            model.openSession(in: alias, startup: .command(command))
        case let .customCommand(alias): model.pendingCustomCommandAlias = alias
        case let .newNamedSession(alias): model.newSession(alias: alias)
        case .newQuickSession: model.requestQuickSession()
        case let .publishPort(workspace): model.requestPublish(workspace: workspace)
        case let .openFiles(alias): system.openFilesWindow(alias: alias)
        case let .openSessionGrid(alias): model.openSessionGrid(alias)
        case let .revealInFinder(path): system.reveal(path: path)
        case let .stats(machine):
            stats.select(machine)
            model.showPage(.stats)
        case let .hostKey(machine):
            model.showHostKey(machine)
        case let .subdomains(machine):
            sites.prefer(machine: machine)
            model.showPage(.subdomains)
        case .newWorkspace: model.requestNewWorkspace()
        case let .addSubdomain(machine):
            if let machine { sites.prefer(machine: machine) }
            model.requestAddSubdomain()
        case .addWidget: model.requestWidgetGallery()
        case let .sendFile(kind): system.chooseFileAndSend(to: kind)
        case .endSession: model.requestEndSession()
        case let .shareSession(ref): model.requestShare(ref)
        case .findFile: model.showFileSearch = true
        case .refresh: refreshCurrentScreen()
        case .toggleSidebar: model.sidebarCollapsed.toggle()
        case .toggleContext: model.contextCollapsed.toggle()
        case .showShortcuts: model.showShortcuts = true
        case .back: model.goBack()
        case .forward: model.goForward()
        case .previousSession: model.moveToPreviousSession()
        case .nextSession: model.moveToNextSession()
        case .maximizePane: model.toggleMaximize()
        case let .openURL(url): system.open(url)
        case .checkForUpdates:
            updates.checkNow()
            model.openSettings(.about)
        case let .logs(action): logs.perform(action)
        case let .preview(request): previews.open(request, inverted: false)
        case .openPreviewField: model.requestPreviewField()
        case .pickColor: system.pickScreenColor(onCopy: model.announceCopiedColor)
        case let .newChat(place, harness):
            chats.startNewChat(place: place, harness: harness)
            model.showChats(store: chats)
        case let .openChat(id): model.showChats(select: id, store: chats)
        case .showChats: model.showChats(store: chats)
        case .showCode: model.appMode = .code
        case .openSchema:
            model.openSchema()
        case .quit: system.quit()
        }
    }

    private func refreshCurrentScreen() {
        switch model.activePage {
        case .stats: stats.refresh()
        case .subdomains: sites.refresh()
        default: model.refreshAll()
        }
    }
}

/// The real outside world. A modal panel cannot open while the palette's
/// key handling still runs, so it waits for the next turn of the run loop.
@MainActor
struct AppPaletteSystem: PaletteSystem {
    let openFiles: (String) -> Void

    func openFilesWindow(alias: String) { openFiles(alias) }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func quit() { NSApp.terminate(nil) }

    func pickScreenColor(onCopy: @escaping @MainActor (String) -> Void) {
        DispatchQueue.main.async { ScreenColorPicker.pick(onCopy: onCopy) }
    }

    func chooseFileAndSend(to kind: TerminalKind) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.prompt = "Send"
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            PaneUploadStore.shared.receive(urls: panel.urls, on: kind)
            TerminalRegistry.shared.requestFocus(kind)
        }
    }
}
