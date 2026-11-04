import SwiftUI
import DevmachineCore
import AppKit
import HarnessUsageKit

@main
struct DevmachineApp: App {
    private let harnessSettingsFacade: HarnessSettingsFacade
    @StateObject private var model = AppModel(cache: .shared)
    @StateObject private var prStore: PRStore
    @StateObject private var filesStore = FilesStore()
    @StateObject private var caddyStore = CaddyStore(cache: .shared)
    @StateObject private var skillsStore = SkillsStore()
    @StateObject private var recentCommandStore = RecentCommandStore()
    @StateObject private var statsStore: StatsStore
    @StateObject private var healthCheckStore = HealthCheckStore()
    @StateObject private var usageStore: HarnessUsageStore
    @StateObject private var settingsStore = SettingsStore.shared
    @StateObject private var wallpaperStore = WallpaperStore()
    @StateObject private var viewerStore = DemoMode.isActive ? DemoSnapshots.demoFileViewerStore() : FileViewerStore()
    @StateObject private var fileTreeStore = FileTreeStore()
    @StateObject private var fileSearchStore = FileSearchStore()
    @StateObject private var paletteRecents = PaletteRecentsStore()
    @StateObject private var updates: UpdateController

    init() {
        _ = SettingsStore.shared
        AppLog.recordLaunch()
        LogFiles.shared.startWatching()
        ScrollBarStyle.apply()
        MainWindowSizer.readSavedFrame()
        let updates = UpdateController.live()
        _updates = StateObject(wrappedValue: updates)
        let prs = PRStore()
        let stats = StatsStore()
        _prStore = StateObject(wrappedValue: prs)
        _statsStore = StateObject(wrappedValue: stats)
        let facade = HarnessSettingsFacade()
        harnessSettingsFacade = facade
        HomeBoardController.shared.defaultBoard = { canvasWidth in
            let settings = SettingsStore.shared.settings ?? .empty
            let ids = DemoMode.isActive
                ? DemoData.usageProviders.map(\.harnessID)
                : facade.usageRegistrations(for: settings).map(\.descriptor.id.rawValue)
            return DefaultBoard.make(
                harnesses: WidgetContract.current.allowed(ids, from: "harnesses"), canvasWidth: canvasWidth,
                machines: stats.machines.count)
        }
        WidgetCompatibilityStore.shared.onUpdated = {
            updates.checkNow()
            HomeBoardController.shared.reload()
            StackBoardController.reloadAll()
            MenubarController.shared.reload()
        }
        Task.detached(priority: .utility) { facade.refreshAvailability() }
        // `DEVMACHINE_DEMO=1`: every store seeds itself from `DemoData` (see
        // `DemoMode.swift`) instead of reading real usage files, the CLI, or
        // ssh/gh. This is the one place that picks a provider list, so it is
        // also the one place that swaps in the demo providers.
        let providers: [any HarnessUsageProvider]
        if DemoMode.isActive {
            providers = DemoData.usageProviders
        } else {
            let settings = SettingsStore.shared.settings ?? .empty
            providers = facade.usageRegistrations(for: settings).map(\.provider)
        }
        let usage = HarnessUsageStore(providers: providers)
        _usageStore = StateObject(wrappedValue: usage)
        MenubarController.shared.start(prs: prs, providers: AppWidgetProviders(usage: usage, stats: stats, prs: prs))
        if !DemoMode.isActive, NSClassFromString("XCTestCase") == nil {
            QuickChatPanelController.shared.start()
        }
    }

    static func newItemTitle(_ mode: AppMode) -> String {
        switch mode {
        case .chats: return "New Chat"
        case .schedule: return "New Task"
        case .code: return "New Session"
        }
    }

    private var metrics: DMMetrics {
        DMMetrics(scale: settingsStore.effectiveUIFontScale)
    }

    var body: some Scene {
        // Single main window (Window, not WindowGroup) so the menubar "Open"
        // can reliably bring it to front via openWindow(id: "main").
        Window("Devmachine", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.jobs)
                .environmentObject(filesStore)
                .environmentObject(skillsStore)
                .environmentObject(recentCommandStore)
                .environmentObject(caddyStore)
                .environmentObject(statsStore)
                .environmentObject(prStore)
                .environmentObject(healthCheckStore)
                .environmentObject(usageStore)
                .environmentObject(settingsStore)
                .environmentObject(SessionShareStore.shared)
                .environment(\.harnessSettingsFacade, harnessSettingsFacade)
                .environment(\.widgetOptionSources, .live(stats: statsStore, model: model, usage: usageStore, facade: harnessSettingsFacade))
                .environment(\.dmMetrics, metrics)
                .environment(\.dmOpenCLIUpdate, { [model] in model.openSettings(.about) })
                .id(settingsStore.effectiveUIFontScale)
                .onAppear { DMFont.scale = settingsStore.effectiveUIFontScale }
                .onAppear {
                    let chat = SessionChatStore.shared
                    SessionShareStore.shared.onChange = { chat.track($0) }
                    SessionShareStore.shared.startPolling()
                }
                .onAppear {
                    let stats = statsStore
                    caddyStore.statsSnapshot = { stats.state(for: $0)?.snapshot }
                    let readiness = MachineReadinessStore.shared
                    model.followSyncLock(readiness.$snapshot.map { $0?.lock })
                    model.loginHolds.follow(readiness.$snapshot.map { $0?.machineLogins })
                    model.attemptWithoutWorkspace = { stats.attemptLogin(machine: $0) }
                    readiness.onConfigurationChanged = { [weak model] in
                        model?.reloadConfiguration()
                        stats.loadMachines()
                        MachinesStore.shared.requestLoad()
                    }
                    model.onLeftOnboarding = {
                        stats.loadMachines()
                        MachinesStore.shared.requestLoad()
                        MachineReadinessStore.shared.requestCheck()
                        HomeBoardController.shared.reload()
                    }
                    readiness.onPrepared = { [weak model] machine in
                        model?.refreshWorkspaces(onMachine: machine)
                        stats.refresh()
                    }
                    HostKeyStore.shared.onTrusted = { [weak model] machine in
                        model?.hostKeyResolved(onMachine: machine)
                        stats.refresh()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    MachineReadinessStore.shared.requestCheckIfStale()
                }
                .onAppear {
                    DemoSnapshots.runIfNeeded(DemoSnapshots.Environment(
                        model: model, prStore: prStore, usageStore: usageStore, caddyStore: caddyStore,
                        settingsStore: settingsStore, wallpaperStore: wallpaperStore,
                        harnessSettingsFacade: harnessSettingsFacade, statsStore: statsStore,
                        viewerStore: viewerStore))
                }
                .onChange(of: settingsStore.effectiveUIFontScale) { _, scale in
                    DMFont.scale = scale
                }
                .onChange(of: model.activePage) { old, new in
                    if old == .setup, new != .setup { settingsStore.leaveSettingsPage() }
                }
                .onChange(of: settingsStore.settings?.enabledHarnesses) { _, _ in
                    let settings = settingsStore.settings ?? .empty
                    usageStore.configure(
                        providers: harnessSettingsFacade.usageRegistrations(for: settings).map(\.provider))
                    if usageStore.isObserved { usageStore.refresh(force: true) }
                }
                .environmentObject(wallpaperStore)
                .environmentObject(viewerStore)
                .environmentObject(fileTreeStore)
                .environmentObject(fileSearchStore)
                .environmentObject(paletteRecents)
                .environmentObject(updates)
                .onAppear {
                    updates.start()
                    #if DEBUG
                    RelaunchRehearsal.run(updates)
                    #endif
                }
                .frame(
                    minWidth: MainWindowSizing.minimum.width, maxWidth: .infinity,
                    minHeight: MainWindowSizing.minimum.height, maxHeight: .infinity)
                .background(MainWindowSizer().frame(width: 0, height: 0))
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(MainWindowSizing.preferred)
        .commands {
            CommandGroup(replacing: .newItem) { }
            // Replaces File > Close so ⌘W closes the tab on screen (the
            // session keeps running); every other case still closes the key
            // window. ⇧⌘W is the one that asks to end the session.
            CommandGroup(replacing: .saveItem) {
                Button("Close") { CloseCommand.perform(model: model) }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("Home") { model.goHome() }
                    .keyboardShortcut("0", modifiers: .command)
                Button(Self.newItemTitle(model.appMode)) {
                    switch model.appMode {
                    case .chats: model.showNewChat()
                    case .schedule: ScheduledStore.shared.requestNewTask()
                    case .code: model.requestQuickSession()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("End Session…") { model.requestEndSession() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.endableSession == nil)
                Divider()
                Button("Previous Session") { model.moveToPreviousSession() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button("Next Session") { model.moveToNextSession() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                Divider()
                Button("Back") { model.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                Button("Forward") { model.goForward() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.activePage = model.activePage == .setup ? nil : .setup }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("Check for Updates…") {
                    updates.checkNow()
                    model.openSettings(.about)
                }
                .disabled(updates.currentVersion == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.showShortcuts = true }
                    .keyboardShortcut("?", modifiers: .command)
                LogsMenu(files: LogFiles.shared)
            }
            // Real menu commands, not hidden buttons: a key equivalent in the
            // menu is handled before the key reaches the focused view, and the
            // terminal is a view from AppKit that holds first responder, which
            // is where the hidden-button shortcuts were being lost.
            CommandGroup(after: .sidebar) {
                Button("Code") { model.appMode = .code }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Chats") { model.showChats() }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Schedule") { model.showPage(.scheduled) }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Toggle Sidebar") {
                    withAnimation(.easeInOut(duration: 0.18)) { model.sidebarCollapsed.toggle() }
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Toggle Context Panel") {
                    withAnimation(.easeInOut(duration: 0.18)) { model.contextCollapsed.toggle() }
                }
                .keyboardShortcut("j", modifiers: .command)
                Divider()
                Button("Find File…") { model.showFileSearch.toggle() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Command Palette…") { model.showCommandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Maximize Pane") { model.toggleMaximize() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
        }

        Window("Files", id: "files") {
            FilesView()
                .environmentObject(filesStore)
                .environmentObject(viewerStore)
                .environmentObject(fileTreeStore)
                .environmentObject(model)
                .environment(\.dmMetrics, metrics)
        }
        .defaultSize(width: 520, height: 600)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(prStore)
                .environmentObject(usageStore)
                .environmentObject(statsStore)
                .environmentObject(model)
                .environmentObject(MenubarController.shared)
                .environment(\.harnessSettingsFacade, harnessSettingsFacade)
                .environment(\.widgetOptionSources, .live(stats: statsStore, model: model, usage: usageStore, facade: harnessSettingsFacade))
                .environment(\.dmMetrics, metrics)
        } label: {
            MenuBarLabelHost(label: MenubarController.shared.label)
        }
        .menuBarExtraStyle(.window)
    }
}
