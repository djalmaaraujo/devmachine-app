import SwiftUI
import DevmachineCore
import AppKit

struct ContentView: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel
    @EnvironmentObject private var fileSearch: FileSearchStore
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var viewerStore: FileViewerStore
    @EnvironmentObject private var recentCommands: RecentCommandStore
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var caddy: CaddyStore
    @EnvironmentObject private var updates: UpdateController
    @EnvironmentObject private var jobs: MachineJobCenter
    @State private var dragStartWidth: CGFloat? = nil
    @State private var contextDragStartWidth: CGFloat?
    @StateObject private var quickPublish = QuickPublishState()
    @ObservedObject private var previews = PreviewStore.shared
    @ObservedObject private var split = DocumentSplitState.shared
    @State private var sidebarButtonFrame: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Onboarding owns the whole window until the Mac is set up or the
            // person skips it: nothing else starts (no sweep, no stats, no
            // context) before then. Later, a machine without the devmachine-app
            // package does not block the app; it gets its own Prepare card.
            if model.showsOnboarding {
                OnboardingPage(
                    onStart: { Task { await model.completeOnboarding(saving: settingsStore) } },
                    onSkip: { Task { await model.skipOnboarding(saving: settingsStore) } })
            } else {
                mainRow
                    .onAppear { stats.start() }
                    .environment(\.collapsedSidebarButtonFrame, model.sidebarCollapsed ? sidebarButtonFrame : nil)
                if model.sidebarCollapsed {
                    collapsedSidebarButton
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.windowSpace)) } action: {
                            sidebarButtonFrame = $0
                        }
                }
            }
        }
        .coordinateSpace(.named(Self.windowSpace))
        .background(Color.dmSidebarBg)
        .overlay {
            if model.showFileSearch, let target = model.commandTarget(for: model.selection) {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { model.showFileSearch = false }
                    FileSearchPaletteView(store: fileSearch, target: target)
                        .environmentObject(model)
                        .padding(.top, m.pt(110))
                }
                .transition(.opacity)
            }
            if model.showCommandPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { model.showCommandPalette = false }
                    CommandPaletteView()
                        .environmentObject(model)
                        .padding(.top, m.pt(110))
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: m.space.md) {
                if updates.showsBanner {
                    UpdateBanner()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if updates.showsCLIBanner {
                    CLIUpdateBanner()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if updates.showsPackagesBanner {
                    PackagesUpdateBanner()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                MachineJobStack()
                ForEach(caddy.jobs) { job in
                    PublishJobCard(
                        job: job,
                        onRetry: { caddy.retry(job.id) },
                        onDismiss: { caddy.dismiss(job.id) })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                ForEach(model.activeTasks) { task in
                    DMToastCard(task: task)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                TransferNoticeOverlay()
            }
            .padding(m.pt(18))
            .animation(.easeInOut(duration: 0.2), value: model.activeTasks)
            .animation(.easeInOut(duration: 0.2), value: caddy.jobs)
            .animation(.easeInOut(duration: 0.2), value: updates.showsBanner)
            .animation(.easeInOut(duration: 0.2), value: updates.showsCLIBanner)
            .animation(.easeInOut(duration: 0.2), value: updates.showsPackagesBanner)
            .animation(.easeInOut(duration: 0.2), value: jobs.jobs.map(\.id))
            .animation(.easeInOut(duration: 0.2), value: jobs.jobs.map(\.phase))
        }
        .onAppear {
            model.settings = settingsStore.settings
            model.checkCLIAndProceed(isConfigured: settingsStore.isConfigured)
        }
        .onReceive(settingsStore.$settings) { model.settings = $0 }
        .onChange(of: model.pendingPublishWorkspace) { _, workspace in
            guard let workspace else { return }
            model.pendingPublishWorkspace = nil
            quickPublish.start(workspace: workspace, stats: stats)
        }
        .quickPublishSheet(quickPublish, settings: settingsStore.settings, workspaces: model.visibleWorkspaces)
        .sheet(isPresented: $updates.showsDialog) {
            UpdateDialog().environmentObject(updates)
        }
        .sheet(isPresented: Binding(
            get: { model.hostKeyMachine != nil },
            set: { if !$0 { model.closeHostKey() } }
        )) {
            if let machine = model.hostKeyMachine {
                HostKeySheet(store: HostKeyStore.shared, machine: machine)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $model.showShortcuts) {
            ShortcutsSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showNewSessionChooser) {
            QuickSessionSheet().environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingNewSessionAlias != nil },
            set: { if !$0 { model.pendingNewSessionAlias = nil } }
        )) {
            NewSessionSheet(alias: model.pendingNewSessionAlias ?? "")
                .environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingCustomCommandAlias != nil },
            set: { if !$0 { model.pendingCustomCommandAlias = nil } }
        )) {
            if let alias = model.pendingCustomCommandAlias {
                CustomCommandSheet(
                    workspaceName: workspaceName(alias),
                    recents: recentCommands.recents(for: alias),
                    onRun: { runCustomCommand($0, in: alias) },
                    onRemove: { recentCommands.remove($0, for: alias) },
                    onCancel: { model.pendingCustomCommandAlias = nil })
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingRename != nil },
            set: { if !$0 { model.pendingRename = nil } }
        )) {
            if let pending = model.pendingRename {
                RenameSheet(alias: pending.alias, oldName: pending.old)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingLocalRename != nil },
            set: { if !$0 { model.pendingLocalRename = nil } }
        )) {
            if let pending = model.pendingLocalRename {
                LocalRenameSheet(handle: pending.handle, currentName: pending.current)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingEndSession != nil },
            set: { if !$0 { model.cancelEndSession() } }
        )) {
            if let request = model.pendingEndSession {
                EndSessionSheet(
                    request: request,
                    onEnd: { model.confirmEndSession() },
                    onCancel: { model.cancelEndSession() })
            }
        }
        .confirmationDialog(
            "Delete \(model.pendingBulkDelete?.count ?? 0) sessions? This kills their tmux sessions.",
            isPresented: Binding(
                get: { model.pendingBulkDelete != nil },
                set: { if !$0 { model.pendingBulkDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pending = model.pendingBulkDelete {
                    model.deleteSessions(pending)
                }
            }
            Button("Cancel", role: .cancel) { model.pendingBulkDelete = nil }
        }
    }

    private var mainRow: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: model.sidebarCollapsed ? 0 : m.pt(model.sidebarWidth))
                .clipped()
            if !model.sidebarCollapsed {
                sidebarDivider
            }
            DocumentSplitView(split: split, showsTrailing: showsDocumentPane) {
                centerPane
            } trailing: {
                DocumentPane()
            }
            .onChange(of: showsDocumentPane) { _, shown in
                if !shown { split.paneClosed() }
            }
            .onChange(of: previews.owner) { _, _ in split.paneClosed() }
            if model.showsContextPanel {
                contextArea
            }
        }
    }

    // A real 6pt drag column (layout element, not an overlay): an overlay spilled
    // onto the sidebar's right edge and stole its clicks.
    private var sidebarDivider: some View {
        ResizeHandle(
            onDrag: { dx in
                let base = dragStartWidth ?? model.sidebarWidth
                if dragStartWidth == nil { dragStartWidth = base }
                model.setSidebarWidth(base + m.base(dx))
            },
            onEnd: { dragStartWidth = nil }
        )
    }

    @ViewBuilder
    private var centerPane: some View {
        ZStack {
            // Under the hidden title bar too: the wallpaper and the cards reach
            // the window's top edge, no content-colored band above them.
            MainPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.dmContentBg)
                .ignoresSafeArea(edges: .top)
            if let page = model.activePage {
                PageHost(page: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.dmContentBg)
                    .transition(.opacity)
            }
        }
    }

    /// The file pane: it sits beside the terminal, the way an editor puts a
    /// file next to a shell, instead of taking a window of its own.
    private var showsDocumentPane: Bool {
        model.activePage == nil
            && DocumentPane.isVisible(fileOpen: viewerStore.isOpen, previewTabs: previews.tabs.count)
    }

    @ViewBuilder
    private var contextArea: some View {
        if model.contextCollapsed {
            ContextCollapsedStrip()
        } else {
            ResizeHandle(
                onDrag: { dx in
                    let base = contextDragStartWidth ?? model.contextWidth
                    if contextDragStartWidth == nil { contextDragStartWidth = base }
                    model.setContextWidth(base - m.base(dx))
                },
                onEnd: { contextDragStartWidth = nil }
            )
            ContextPanel(store: model.context)
                .frame(width: m.pt(model.contextWidth))
        }
    }

    static let windowSpace = "window"

    private var collapsedSidebarButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { model.sidebarCollapsed = false }
        } label: {
            Image(systemName: "sidebar.left")
                .padding(m.pt(9))
                .dmGlass(in: Circle(), stroke: .white.opacity(0.15))
                .shadow(radius: m.pt(6), y: m.pt(2))
        }
        .buttonStyle(DMIconButtonStyle(size: 13, weight: .semibold, tint: .white.opacity(0.9)))
        .help("Open sidebar (⌘B)")
        .padding(.top, m.pt(18))
        .padding(.leading, m.pt(14))
    }

}

private struct PageHost: View {
    let page: AppPage

    var body: some View {
        switch page {
        // `DemoSnapshots.setupInitialSection` only ever differs from
        // `.general` while the website's screenshot walk owns the window.
        case .setup: SetupPage(initialSection: DemoSnapshots.setupInitialSection)
        case .stats: StatsView()
        // `DemoSnapshots.subdomainsInitialTab` only ever differs from `.sites`
        // while the website's screenshot walk owns the window.
        case .subdomains: SubdomainsView(initialTab: DemoSnapshots.subdomainsInitialTab)
        case .stack(let refs): StackGridView(refs: refs).ignoresSafeArea(edges: .top)
        case .addMachine: AddMachinePage()
        case let .operatorChooser(harnesses, last): OperatorChooserPage(harnesses: harnesses, last: last)
        }
    }
}

private struct MainPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            WallpaperBackground(style: .ambient)

            // Only the selected terminal is mounted: the registry owns the process,
            // so an unmounted one keeps running and re-attaches on the next select.
            // A stacked session is mounted by the grid instead — mounting it here as
            // well would pull the shared view out of its grid cell.
            if let selected = model.selection, !isStacked(selected) {
                terminal(for: selected)
            }
            if MainPaneVisibility.showsHome(
                hasSelection: model.selection != nil, activePage: model.activePage) {
                HomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func isStacked(_ item: SidebarItem) -> Bool {
        guard case let .session(alias, name) = item else { return false }
        return model.isStacked(SessionRef(alias: alias, name: name))
    }

    @ViewBuilder
    private func terminal(for item: SidebarItem) -> some View {
        Group {
            switch item {
            case let .localSession(name, path):
                let kind = TerminalKind.local(session: name, path: path)
                TerminalPaneView(kind: kind, translucent: true)
                    .terminalFindBar(for: kind)
                    .terminalUploads(for: kind)
            case let .session(alias, name):
                let kind = TerminalKind.remote(alias: alias, session: name)
                TerminalPaneView(kind: kind, translucent: true)
                    .terminalFindBar(for: kind)
                    .terminalUploads(for: kind)
                    .terminalTransport(for: kind)
            }
        }
        .id(key(item))
        .floatingCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FloatingCardLayout.margin)
    }

    private func key(_ item: SidebarItem) -> String {
        switch item {
        case let .localSession(name, _): return "local/\(name)"
        case let .session(alias, name): return "\(alias)/\(name)"
        }
    }
}

enum MainPaneVisibility {
    static func showsHome(hasSelection: Bool, activePage: AppPage?) -> Bool {
        !hasSelection && activePage == nil
    }
}

private struct RenameSheet: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel
    let alias: String
    let oldName: String
    @State private var name: String

    init(alias: String, oldName: String) {
        self.alias = alias
        self.oldName = oldName
        _name = State(initialValue: oldName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: m.space.lg) {
            Text("Rename \(oldName)").font(.headline)
            TextField("new name", text: $name).frame(width: m.pt(240))
            HStack {
                Spacer()
                DMButton("Cancel", variant: .outline) { model.pendingRename = nil }
                DMButton("Rename") { model.renameSession(alias: alias, old: oldName, new: name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(m.pt(20))
    }
}

private struct LocalRenameSheet: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel
    let handle: String
    let currentName: String
    @State private var name: String

    init(handle: String, currentName: String) {
        self.handle = handle
        self.currentName = currentName
        _name = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: m.space.lg) {
            Text("Rename \(currentName)").font(.headline)
            TextField("new name", text: $name).frame(width: m.pt(240))
            Text("Only the name in the sidebar changes. The shell keeps running.")
                .font(.dm(11))
                .foregroundStyle(Color.dmMuted)
            HStack {
                Spacer()
                DMButton("Cancel", variant: .outline) { model.pendingLocalRename = nil }
                DMButton("Rename") { model.renameLocalSession(handle: handle, to: name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(m.pt(20))
    }
}

private struct NewSessionSheet: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel
    let alias: String
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: m.space.lg) {
            Text("New session in \(alias)").font(.headline)
            TextField("name", text: $name).frame(width: m.pt(240))
            // Where the session starts decides whether its harness can list
            // files there, so it is asked for, not assumed.
            TextField("directory", text: $model.newSessionDirectory).frame(width: m.pt(240))
            // The rule used to be enforced silently: a name with a space closed
            // the sheet and created nothing.
            if let hint = SessionName.hint(for: name) {
                let suggestion = SessionName.suggestion(for: name)
                HStack(spacing: m.space.sm) {
                    Text(hint)
                        .font(.dm(11))
                        .foregroundStyle(Color.dmMuted)
                    if !suggestion.isEmpty {
                        DMButton("Use \(suggestion)", variant: .link, size: .small) { name = suggestion }
                    }
                }
            }
            HStack {
                Spacer()
                DMButton("Cancel", variant: .outline) { model.pendingNewSessionAlias = nil }
                DMButton("Create") {
                    model.confirmNewSession(
                        alias: alias, name: name, directory: model.newSessionDirectory)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!SessionName.isValid(name))
            }
        }
        .padding(m.pt(20))
    }
}

private struct QuickSessionSheet: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel
    @State private var destinationAlias = Workspace.local.alias
    @State private var directory = ""

    private var isLocal: Bool { destinationAlias == Workspace.local.alias }

    var body: some View {
        VStack(alignment: .leading, spacing: m.space.xl) {
            Text("New Session")
                .font(.headline)

            Picker("Workspace", selection: $destinationAlias) {
                ForEach(model.sidebarWorkspaces) { workspace in
                    Text(verbatim: workspace.isLocal ? "This Mac" : workspace.name)
                        .tag(workspace.alias)
                }
            }

            HStack(spacing: m.space.md) {
                TextField(isLocal ? "folder" : "remote folder", text: $directory)
                if isLocal {
                    DMButton("Choose…", variant: .outline, size: .small, action: chooseLocalFolder)
                }
            }

            Text("The configured Terminal or coding harness opens automatically.")
                .font(.dm(11))
                .foregroundStyle(Color.dmMuted)

            HStack {
                Spacer()
                DMButton("Cancel", variant: .outline) { model.showNewSessionChooser = false }
                DMButton("Create") {
                    model.createQuickSession(
                        destinationAlias: destinationAlias, directory: directory)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(m.pt(20))
        .frame(width: m.pt(440))
        .onAppear {
            if directory.isEmpty { directory = model.newSessionDirectory }
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if directory.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url.path
    }
}

extension ContentView {
    fileprivate func workspaceName(_ alias: String) -> String {
        guard let workspace = model.sidebarWorkspaces.first(where: { $0.alias == alias }) else { return alias }
        return workspace.isLocal ? "This Mac" : workspace.name
    }

    fileprivate func runCustomCommand(_ raw: String, in alias: String) {
        guard let command = recentCommands.record(raw, for: alias) else { return }
        model.pendingCustomCommandAlias = nil
        model.openSession(in: alias, startup: .command(command))
    }
}
