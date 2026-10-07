import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DevmachineCore

struct SidebarView: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var filesStore: FilesStore
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var savedCommands: RecentCommandStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.harnessSettingsFacade) private var harnessSettingsFacade
    @ObservedObject private var readiness = MachineReadinessStore.shared
    @ObservedObject private var machines = MachinesStore.shared
    @State private var dragging: SidebarDragItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            ScrollView {
                if model.hasLoadedWorkspaces {
                    workspaceList
                        .transition(.opacity)
                } else {
                    SidebarSkeleton()
                        .transition(.opacity)
                }
            }
            .scrollIndicators(.hidden)
            .animation(.easeOut(duration: 0.2), value: model.hasLoadedWorkspaces)
            .animation(.easeOut(duration: 0.2), value: model.answeredAliases)
            footerRow
        }
        .background(Color.dmSidebarBg)
        .task { await machines.load() }
    }

    private var workspaceList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.sidebarWorkspaces.enumerated()), id: \.element.id) { index, ws in
                if ws.isLocal, AddMachinePrompt.shows(remoteMachines: machines.remoteMachineNames) {
                    AddMachineSidebarButton { model.showPage(.addMachine) }
                        .padding(.horizontal, m.space.md)
                        .padding(.top, m.space.sm)
                }
                groupHeader(
                    ws.name,
                    alias: ws.alias,
                    offline: !ws.isLocal && model.offlineAliases.contains(ws.alias),
                    action: ws.isLocal ? pickLocalFolder : { model.newSession(alias: ws.alias) },
                    filesButton: !ws.isLocal,
                    extraTopSpacing: index > 0
                )
                .sidebarDraggable(.workspace(ws.alias), dragging: $dragging, model: model)
                if let machine = firstSyncMachine(for: ws), let problem = model.sessionProblems[ws.alias] {
                    SessionProblemView(
                        presentation: problem.firstSyncPresentation(workspace: ws.name, machine: machine),
                        retry: { model.retry(alias: ws.alias) })
                } else if let machine = readinessCardMachine(for: ws) {
                    MachineReadinessCard(store: readiness, machine: machine, compact: true)
                        .dmSurface(Color.dmBand, radius: DMRadius.panel)
                        .padding(.horizontal, m.space.md)
                        .padding(.vertical, m.space.xs)
                }
                if let machine = hostKeyCardMachine(for: ws) {
                    HostKeySidebarCard(machine: machine)
                        .dmSurface(Color.dmBand, radius: DMRadius.panel)
                        .padding(.horizontal, m.space.md)
                        .padding(.vertical, m.space.xs)
                }
                if ws.isLocal {
                    ForEach(model.localSessions) { s in
                        localSessionRow(session: s)
                    }
                } else if firstSyncMachine(for: ws) != nil {
                    EmptyView()
                } else if let problem = model.sessionProblems[ws.alias],
                          !(problem.isHostKeyRejected && hostKeyMachine(for: ws) != nil),
                          (model.sessionsByAlias[ws.alias] ?? []).isEmpty {
                    // A refused host key with no machine to review it under
                    // (the configuration unread) still says why.
                    SessionProblemView(
                        presentation: problem.presentation(workspace: ws.name),
                        retry: { model.retry(alias: ws.alias) })
                } else if model.showsSessionSkeleton(alias: ws.alias) {
                    SidebarSkeleton.sessionRows(count: 2, seed: index)
                        .transition(.opacity)
                } else {
                    ForEach(model.sessions(in: ws.alias)) { s in
                        sessionRow(alias: ws.alias, session: s)
                    }
                }
            }
        }
        .padding(.vertical, m.space.sm)
    }

    /// A machine that needs Prepare gets its card once, under the first of
    /// its workspaces the sidebar shows.
    private func readinessCardMachine(for workspace: Workspace) -> String? {
        guard !workspace.isLocal, let machine = readiness.machine(forWorkspace: workspace.name),
              readiness.state(for: machine).needsAttention || readiness.prepareStatus(machine) != nil
        else { return nil }
        let first = model.visibleWorkspaces.first { readiness.machine(forWorkspace: $0.name) == machine }
        return first?.alias == workspace.alias ? machine : nil
    }

    /// The machine whose readiness card would sit under `workspace`, when
    /// that workspace's account and the machine's package both wait for the
    /// first sync: the two become one card.
    private func firstSyncMachine(for workspace: Workspace) -> String? {
        guard let machine = readinessCardMachine(for: workspace),
              SessionProblem.mergesIntoFirstSync(
                  state: readiness.state(for: machine), status: readiness.prepareStatus(machine),
                  problem: model.sessionProblems[workspace.alias])
        else { return nil }
        return machine
    }

    /// A machine whose host key ssh refused gets one card, under the first
    /// of its workspaces the sidebar shows, whether or not older sessions
    /// are still listed: none of them can be opened until it is reviewed.
    private func hostKeyCardMachine(for workspace: Workspace) -> String? {
        guard let machine = hostKeyMachine(for: workspace) else { return nil }
        let first = model.visibleWorkspaces.first { readiness.machine(forWorkspace: $0.name) == machine }
        return first?.alias == workspace.alias ? machine : nil
    }

    /// The machine of `workspace` when any workspace on it has a refused
    /// host key.
    private func hostKeyMachine(for workspace: Workspace) -> String? {
        guard !workspace.isLocal, let machine = readiness.machine(forWorkspace: workspace.name) else { return nil }
        let onMachine = model.visibleWorkspaces.filter { readiness.machine(forWorkspace: $0.name) == machine }
        return onMachine.contains { model.sessionProblems[$0.alias]?.isHostKeyRejected == true } ? machine : nil
    }

    private var footerRow: some View {
        HStack(spacing: 0) {
            footerButton("chart.bar") { model.showPage(.stats) }
                .help("Stats")
            if model.hasCaddyMachine {
                footerButton("globe") { model.showPage(.subdomains) }
                    .help("Subdomains")
            }
            footerButton("gearshape") { model.showPage(.setup) }
                .help("Settings (⌘,)")
            footerButton("sidebar.left") {
                withAnimation(.easeInOut(duration: 0.18)) { model.sidebarCollapsed = true }
            }
            .help("Close sidebar (⌘B)")
        }
        .padding(.horizontal, m.space.lg)
        .padding(.vertical, m.space.md)
    }

    private func footerButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        DMIconButton(
            systemImage: systemImage, size: DMMetrics.baseFontSize, hitSize: DMHitSize.footer,
            fillsWidth: true,
            action: action)
    }

    private var topBar: some View {
        DMSection(
            headerSpacing: 8,
            padding: EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12),
            label: {
                Text("WORKSPACES")
                    .font(.dm(11, weight: .semibold))
                    .foregroundStyle(Color.dmMuted)
                    .kerning(0.8)
            },
            trailing: {
                DMIconButton(systemImage: "arrow.clockwise", size: DMMetrics.baseFontSize) { model.refreshAll() }
                    .help("Refresh")

                Menu {
                    ForEach(model.workspaces) { ws in
                        Button(ws.name) { model.newSession(alias: ws.alias) }
                    }
                    Divider()
                    Button {
                        model.requestNewWorkspace()
                    } label: {
                        Label("New workspace…", systemImage: "person.crop.square.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Color.dmMuted)
                .help("New session or workspace…")
            }
        )
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: m.pt(12))
        }
    }

    @ViewBuilder
    private func groupHeader(
        _ title: String,
        alias: String,
        offline: Bool,
        action: (() -> Void)?,
        filesButton: Bool = true,
        extraTopSpacing: Bool
    ) -> some View {
        DMSection(
            padding: EdgeInsets(top: extraTopSpacing ? 16 : 4, leading: 10, bottom: 4, trailing: 10),
            label: {
                Text(title)
                    .font(.dm(11, weight: .semibold))
                    .foregroundStyle(Color.dmMuted)
                if offline {
                    Circle()
                        .fill(Color.red)
                        .frame(width: m.pt(5), height: m.pt(5))
                        .help("Offline")
                }
            },
            trailing: {
                DMIconButton(
                    systemImage: model.isWorkspaceStacked(alias) ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2",
                    size: 11,
                    tint: model.isWorkspaceStacked(alias) ? Color.accentColor : Color.dmMuted,
                    hitSize: DMHitSize.header
                ) { model.stackWorkspace(alias) }
                .help("Workspace home")

                if filesButton {
                    DMIconButton(systemImage: "folder", size: 11, hitSize: DMHitSize.header) {
                        openFiles(alias: alias)
                    }
                    .help("Files…")
                }

                if let action {
                    newSessionButton(alias: alias, action: action)
                }
            }
        )
        .contextMenu {
            Button("Open workspace home") { model.stackWorkspace(alias) }
            Button("Files…") { openFiles(alias: alias) }
            if alias != Workspace.local.alias, model.hasCaddyMachine {
                Button("Publish a port…") {
                    model.requestPublish(workspace: title)
                }
            }
        }
    }

    /// Picks what the new session runs: a plain shell, one of the enabled
    /// harnesses, a saved command, or a command typed by hand. "New session…"
    /// keeps the named, folder-first flow that runs the workspace's
    /// configured program.
    private func newSessionButton(alias: String, action: @escaping () -> Void) -> some View {
        Menu {
            ForEach(harnessSettingsFacade.launchOptions(
                for: settingsStore.settings ?? .empty,
                on: alias == Workspace.local.alias ? .thisMac : .remote)) { option in
                Button {
                    model.openSession(in: alias, startup: .program(option.choice))
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
            }
            let commands = savedCommands.recents(for: alias)
            if !commands.isEmpty {
                Divider()
                ForEach(commands, id: \.self) { command in
                    Button {
                        savedCommands.record(command, for: alias)
                        model.openSession(in: alias, startup: .command(command))
                    } label: {
                        Label(command, systemImage: "chevron.forward.square")
                    }
                }
            }
            Divider()
            Button {
                model.pendingCustomCommandAlias = alias
            } label: {
                Label("Custom command…", systemImage: "square.and.pencil")
            }
            Divider()
            Button(alias == Workspace.local.alias ? "New session in folder…" : "New named session…", action: action)
        } label: {
            Image(systemName: "plus")
                .font(.dm(11))
                .foregroundStyle(Color.dmMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: m.hit.header.width, height: m.hit.header.height)
        .help("New session…")
    }

    private func openFiles(alias: String) {
        filesStore.open(.host(alias: alias))
        openWindow(id: "files")
    }

    private func localSessionRow(session s: LocalSession) -> some View {
        let item = SidebarItem.localSession(name: s.handle, path: s.path)
        let isOpen = model.activePage == nil && model.selection == item
        let live = model.localSessionIsLive(s)
        return row(
            title: s.name,
            badges: model.badges(for: s),
            // A session the multiplexer does not have yet is a name waiting for
            // a shell, so it carries no client count.
            windows: live ? 1 : nil,
            selected: isOpen
        )
            .contentShape(Rectangle())
            .onTapGesture { model.clickLocalSession(item) }
            .help(live ? s.path : "\(s.path) — not started")
            .sidebarDraggable(.session(s.handle, in: Workspace.local.alias), dragging: $dragging, model: model)
            .contextMenu {
                Button("Rename…") {
                    model.pendingLocalRename = (handle: s.handle, current: s.name)
                }
                if s.handle != Workspace.operatorSession {
                    Button("Remove", role: .destructive) {
                        model.askToEndSession(.localSession(name: s.handle, path: s.path))
                    }
                }
            }
    }

    /// Asks for the folder the shell starts in. The name comes from the folder,
    /// so there is nothing else to fill in.
    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addLocalSession(path: url.path)
    }

    private func sessionRow(alias: String, session s: TmuxSession) -> some View {
        let ref = SessionRef(alias: alias, name: s.name)
        // A page (stats/subdomains/stack) covers the terminal, so the old
        // selection is not "where you are" — only stacked sessions are.
        let isOpen = model.activePage == nil && model.selection == .session(alias: alias, name: s.name)
        let isMultiSelected = model.selectedSessions.contains(ref)
        return row(
            title: s.name,
            badges: model.badges(for: s),
            windows: s.windows,
            selected: isOpen || isMultiSelected || model.isStacked(ref)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) {
                model.cmdClickSession(ref)
            } else if mods.contains(.shift) {
                model.shiftClickSession(ref)
            } else {
                model.clickSession(ref)
            }
        }
        .sidebarDraggable(.session(s.name, in: alias), dragging: $dragging, model: model)
        .contextMenu {
            if model.selectedSessions.count > 1 && model.selectedSessions.contains(ref) {
                Button("Stack to Home") {
                    model.stackSessions(Array(model.selectedSessions))
                }
                Button("Delete \(model.selectedSessions.count) sessions", role: .destructive) {
                    model.pendingBulkDelete = Array(model.selectedSessions)
                }
            } else {
                Button("Open") {
                    model.clickSession(ref)
                }
                Button("Rename…") {
                    model.pendingRename = (alias: alias, old: s.name)
                }
                Button("Delete", role: .destructive) {
                    model.askToEndSession(.session(alias: alias, name: s.name))
                }
            }
        }
    }

    /// Harness badges appear before the client count only under the pointer: a
    /// sidebar full of marks is noise, while hover makes one row easy to check.
    /// Settings → Harnesses can move a harness's icon before the name instead.
    private func row(
        title: String,
        badges: [HarnessBadgePresentation],
        windows: Int?,
        selected: Bool
    ) -> some View {
        let icons = HarnessIconLibrary.bundled
        let glyph = SessionRowGlyph(
            showsHarnessIcons: settingsStore.settings?.showsHarnessIcons ?? false,
            badges: badges,
            hasIcon: icons.hasIcon(for:))
        return DMRow(
            leading: glyph.reservesLeadingSlot ? AnyView(
                SidebarHarnessIcon(
                    icon: glyph.icon.flatMap {
                        icons.icon(for: $0, style: settingsStore.settings?.harnessIconStyle ?? .color)
                    },
                    showsTerminal: glyph.showsTerminal,
                    help: badges.first { $0.id == glyph.icon }?.helpText)
            ) : nil,
            title: title,
            selected: selected,
            trailing: windows.map { count in
                AnyView(Text(verbatim: "\(count)").font(.dm(11)).foregroundStyle(Color.dmMuted))
            },
            trailingHover: glyph.hoverBadges.isEmpty ? nil : AnyView(
                HStack(spacing: m.space.xs) {
                    ForEach(glyph.hoverBadges) { badge in
                        Image(systemName: badge.systemImage)
                            .font(.dm(5))
                            .foregroundStyle(badge.color)
                            .help(badge.helpText)
                    }
                }
            )
        )
    }
}

/// The 14-point slot before a session's name, a terminal when no harness
/// runs in it, so every name in the list starts at the same place.
private struct SidebarHarnessIcon: View {
    @Environment(\.dmMetrics) private var m
    let icon: HarnessIcon?
    let showsTerminal: Bool
    let help: String?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon.image)
                    .renderingMode(icon.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(Color.dmRowText)
                    .help(help ?? "")
            } else if showsTerminal {
                Image(systemName: "apple.terminal")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.dmRowText)
                    .help("A terminal session")
            } else {
                Color.clear
            }
        }
        .frame(width: m.pt(14), height: m.pt(14))
    }
}

/// The workspace list before it is read: group headers and session rows in
/// the sidebar's own sizes, stretching with its width.
struct SidebarSkeleton: View {
    @Environment(\.dmMetrics) private var m
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<3, id: \.self) { group in
                DMSkeleton {
                    DMSection(
                        padding: EdgeInsets(top: group > 0 ? 16 : 4, leading: 10, bottom: 4, trailing: 10),
                        label: { DMSkeletonText(size: 11, weight: .semibold, width: .fixed([54, 40, 66][group])) },
                        trailing: { Color.clear.frame(width: m.hit.header.width, height: m.hit.header.height) }
                    )
                }
                Self.sessionRows(count: [3, 2, 2][group], seed: group)
            }
        }
        .padding(.vertical, m.space.sm)
    }

    static func sessionRows(count: Int, seed: Int) -> some View {
        let m = DMMetrics.current
        return DMSkeleton {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: m.space.md) {
                        DMSkeletonText(size: 13, width: .varied(seed * 2 + index, shares: [0.5, 0.34, 0.62, 0.42, 0.56]))
                        DMSkeletonText(size: 11, width: .fixed(7))
                    }
                    .padding(.horizontal, m.row.horizontal)
                    .padding(.vertical, m.row.vertical)
                    .padding(.horizontal, m.row.outer)
                }
            }
        }
    }
}

private extension View {
    /// Makes a sidebar header or row both a drag source and a drop target.
    /// The order changes while the pointer moves, so the rows open up under
    /// it; the drop itself only ends the drag.
    func sidebarDraggable(
        _ item: SidebarDragItem, dragging: Binding<SidebarDragItem?>, model: AppModel
    ) -> some View {
        onDrag {
            dragging.wrappedValue = item
            return NSItemProvider(object: item.token as NSString)
        }
        .onDrop(of: [.plainText], delegate: SidebarDropDelegate(target: item, dragging: dragging, model: model))
    }
}

private struct SidebarDropDelegate: DropDelegate {
    let target: SidebarDragItem
    @Binding var dragging: SidebarDragItem?
    let model: AppModel

    private var action: SidebarDrop.Action? {
        dragging.map { SidebarDrop.action(dragging: $0, over: target) }
    }

    func validateDrop(info: DropInfo) -> Bool {
        action != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            _ = model.moveInSidebar(dragging, over: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let action else { return nil }
        return DropProposal(operation: action == .refuse ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil }
        return action.map { $0 != .refuse } ?? false
    }
}
