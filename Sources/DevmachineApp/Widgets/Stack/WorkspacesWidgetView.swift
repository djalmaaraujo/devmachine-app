import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DevmachineCore

struct WorkspacesWidgetView: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var filesStore: FilesStore
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var savedCommands: RecentCommandStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.harnessSettingsFacade) private var harnessSettingsFacade
    @ObservedObject private var readiness = MachineReadinessStore.shared
    @ObservedObject private var machines = MachinesStore.shared
    @ObservedObject private var shares = SessionShareStore.shared
    @State private var dragging: SidebarDragItem?

    var body: some View {
        Group {
            if model.hasLoadedWorkspaces {
                workspaceList
                    .transition(.opacity)
            } else {
                SidebarSkeleton()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.hasLoadedWorkspaces)
        .animation(.easeOut(duration: 0.2), value: model.answeredAliases)
    }

    private var workspaceList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.sidebarWorkspaces.enumerated()), id: \.element.id) { index, ws in
                if ws.isLocal, AddMachinePrompt.shows(remoteMachines: machines.remoteMachineNames) {
                    AddMachineSidebarButton { model.showPage(.addMachine) }
                        .padding(.horizontal, m.space.md)
                        .padding(.top, m.space.sm)
                }
                let activity = firstSyncActivity(for: ws)
                groupHeader(
                    ws.name,
                    alias: ws.alias,
                    offline: !ws.isLocal && model.offlineAliases.contains(ws.alias),
                    action: ws.isLocal ? pickLocalFolder : { model.newSession(alias: ws.alias) },
                    filesButton: !ws.isLocal,
                    extraTopSpacing: index > 0,
                    disabled: activity != nil
                )
                .sidebarDraggable(.workspace(ws.alias), dragging: $dragging, model: model)
                if let activity {
                    FirstSyncActivityRow(activity: activity)
                        .transition(.opacity)
                } else if let machine = firstSyncMachine(for: ws), let problem = model.sessionProblems[ws.alias] {
                    SessionProblemView(
                        presentation: problem.firstSyncPresentation(workspace: ws.name, machine: machine),
                        retry: { model.retry(alias: ws.alias) })
                } else if let machine = readinessCardMachine(for: ws) {
                    MachineReadinessCard(store: readiness, machine: machine, compact: true)
                        .dmSurface(Color.dmBand, radius: DMRadius.panel)
                        .padding(.horizontal, m.space.md)
                        .padding(.vertical, m.space.xs)
                }
                if let pause = pollPauseCard(for: ws) {
                    PollPauseSidebarCard(
                        notice: pause.notice(workspace: ws.name), reason: pause.reason,
                        retry: { model.retry(alias: ws.alias) })
                        .dmSurface(Color.dmBand, radius: DMRadius.panel)
                        .padding(.horizontal, m.space.md)
                        .padding(.vertical, m.space.xs)
                }
                if let machine = loginWaitingCardMachine(for: ws) {
                    LoginWaitingSidebarCard(machine: machine)
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
                } else if activity != nil || firstSyncMachine(for: ws) != nil {
                    EmptyView()
                } else if let problem = model.sessionProblems[ws.alias], model.pollPauses[ws.alias] == nil,
                          !(problem.isHostKeyRejected && hostKeyMachine(for: ws) != nil),
                          !(problem.isLoginWaiting && loginWaitingMachine(for: ws) != nil),
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

    /// A sync on its way for a workspace that waits for its first one.
    private func firstSyncActivity(for workspace: Workspace) -> FirstSyncActivity? {
        guard !workspace.isLocal else { return nil }
        return model.firstSyncActivity(
            alias: workspace.alias, machine: readiness.machine(forWorkspace: workspace.name))
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

    /// A paused workspace says so under its name. A machine paused as a
    /// whole (unreachable, or several refused logins) gets one card, under the
    /// first of its workspaces the sidebar shows.
    private func pollPauseCard(for workspace: Workspace) -> PollPause? {
        guard let pause = model.pollPauses[workspace.alias] else { return nil }
        guard pause.reason.coversMachine, let machine = pause.machine else { return pause }
        let first = model.visibleWorkspaces.first {
            let other = model.pollPauses[$0.alias]
            return other?.reason == pause.reason && other?.machine == machine
        }
        return first?.alias == workspace.alias ? pause : nil
    }

    /// A machine whose host key ssh refused gets one card, under the first
    /// of its workspaces the sidebar shows, whether or not older sessions
    /// are still listed: none of them can be opened until it is reviewed.
    private func hostKeyCardMachine(for workspace: Workspace) -> String? {
        guard let machine = hostKeyMachine(for: workspace) else { return nil }
        let first = model.visibleWorkspaces.first { readiness.machine(forWorkspace: $0.name) == machine }
        return first?.alias == workspace.alias ? machine : nil
    }

    /// A machine waiting for the SSH agent to approve the key gets one card,
    /// under the first of its workspaces the sidebar shows, even while older
    /// sessions are still listed: it is the one thing to do.
    private func loginWaitingCardMachine(for workspace: Workspace) -> String? {
        guard let machine = loginWaitingMachine(for: workspace) else { return nil }
        let first = model.visibleWorkspaces.first { readiness.machine(forWorkspace: $0.name) == machine }
        return first?.alias == workspace.alias ? machine : nil
    }

    private func loginWaitingMachine(for workspace: Workspace) -> String? {
        guard !workspace.isLocal, let machine = readiness.machine(forWorkspace: workspace.name) else { return nil }
        let onMachine = model.visibleWorkspaces.filter { readiness.machine(forWorkspace: $0.name) == machine }
        return onMachine.contains { model.sessionProblems[$0.alias]?.isLoginWaiting == true } ? machine : nil
    }

    /// The machine of `workspace` when any workspace on it has a refused
    /// host key.
    private func hostKeyMachine(for workspace: Workspace) -> String? {
        guard !workspace.isLocal, let machine = readiness.machine(forWorkspace: workspace.name) else { return nil }
        let onMachine = model.visibleWorkspaces.filter { readiness.machine(forWorkspace: $0.name) == machine }
        return onMachine.contains { model.sessionProblems[$0.alias]?.isHostKeyRejected == true } ? machine : nil
    }

    @ViewBuilder
    private func groupHeader(
        _ title: String,
        alias: String,
        offline: Bool,
        action: (() -> Void)?,
        filesButton: Bool = true,
        extraTopSpacing: Bool,
        disabled: Bool = false
    ) -> some View {
        DMSection(
            padding: EdgeInsets(top: extraTopSpacing ? 16 : 4, leading: 10, bottom: 4, trailing: 10),
            label: {
                Text(title)
                    .font(.dm(11, weight: .semibold))
                    .foregroundStyle(Color.dmMuted)
                    .opacity(disabled ? 0.5 : 1)
                if offline {
                    Circle()
                        .fill(Color.red)
                        .frame(width: m.pt(5), height: m.pt(5))
                        .help("Offline")
                }
            },
            trailing: {
                Group {
                    DMIconButton(
                        systemImage: model.isWorkspaceInSessionGrid(alias) ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2",
                        size: 11,
                        tint: model.isWorkspaceInSessionGrid(alias) ? Color.accentColor : Color.dmMuted,
                        hitSize: DMHitSize.header
                    ) { model.openSessionGrid(alias) }
                    .help("Session grid")
                    .demoClickTarget("grid:\(alias)")

                    if filesButton {
                        DMIconButton(systemImage: "folder", size: 11, hitSize: DMHitSize.header) {
                            openFiles(alias: alias)
                        }
                        .help("Browse files…")
                    }

                    if let action {
                        newSessionButton(alias: alias, action: action)
                    }
                }
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
            }
        )
        .contextMenu {
            Button("Open session grid") { model.openSessionGrid(alias) }
            Button("Browse files…") { openFiles(alias: alias) }
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
            selected: isOpen,
            indicators: model.indicators(for: s)
        )
            .contentShape(Rectangle())
            .demoClickTarget("local:\(s.handle)")
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
        // A page (stats/subdomains/session grid) covers the terminal, so the old
        // selection is not "where you are" — only sessions in the session grid are.
        let isOpen = model.activePage == nil && model.selection == .session(alias: alias, name: s.name)
        let isMultiSelected = model.selectedSessions.contains(ref)
        let shared = shares.liveShare(alias: alias, session: s.name)
        return row(
            title: s.name,
            badges: model.badges(for: s),
            windows: s.windows,
            selected: isOpen || isMultiSelected || model.isInSessionGrid(ref),
            shared: shared,
            indicators: s.indicators
        )
        .contentShape(Rectangle())
        .demoClickTarget("session:\(alias)/\(s.name)")
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
                Button("Show in session grid") {
                    model.showSessionGrid(Array(model.selectedSessions))
                }
                Button("End \(model.selectedSessions.count) sessions", role: .destructive) {
                    model.pendingBulkDelete = Array(model.selectedSessions)
                }
            } else {
                Button("Open") {
                    model.clickSession(ref)
                }
                Button("Rename…") {
                    model.pendingRename = (alias: alias, old: s.name)
                }
                Divider()
                if let shared {
                    Button("Open chat") { model.openChat(ref) }
                    if let url = shared.url {
                        Button("Copy share link") { Pasteboard.copy(url) }
                    }
                    Button("Add 30 minutes") { Task { await shares.extend(shared) } }
                    Button("Stop sharing") { Task { await shares.stop(shared) } }
                } else {
                    Button("Share…") { model.requestShare(ref) }
                }
                Divider()
                Button("End session", role: .destructive) {
                    model.askToEndSession(.session(alias: alias, name: s.name))
                }
            }
        }
    }

    /// Harness badges appear before the client count only under the pointer: a
    /// sidebar full of marks is noise, while hover makes one row easy to check.
    /// Settings → Coding agents can move a harness's icon before the name instead.
    private func row(
        title: String,
        badges: [HarnessBadgePresentation],
        windows: Int?,
        selected: Bool,
        shared: SessionShareRecord? = nil,
        indicators: SessionIndicators? = nil
    ) -> some View {
        let icons = HarnessIconLibrary.bundled
        let shown = SessionRowIndicators(indicators, settings: settingsStore.settings ?? .empty)
        let glyph = SessionRowGlyph(
            showsHarnessIcons: settingsStore.settings?.showsHarnessIcons ?? false,
            badges: badges,
            hasIcon: icons.hasIcon(for:))
        let settings = settingsStore.settings ?? .empty
        let reservesSlot = glyph.reservesLeadingSlot || settings.showsBusySpinner || settings.showsAttention
        return DMRow(
            leading: reservesSlot ? AnyView(
                Group {
                    switch shown.leading {
                    case .spinner:
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(14.0 / 16.0)
                    case .attention:
                        Circle()
                            .fill(Color.orange)
                            .frame(width: m.pt(8), height: m.pt(8))
                            .help("The agent asked for attention")
                    case .none where glyph.reservesLeadingSlot:
                        SidebarHarnessIcon(
                            icon: glyph.icon.flatMap {
                                icons.icon(for: $0, style: settingsStore.settings?.harnessIconStyle ?? .color)
                            },
                            showsTerminal: glyph.showsTerminal,
                            help: badges.first { $0.id == glyph.icon }?.helpText)
                    case .none:
                        Color.clear
                    }
                }
                .frame(width: m.pt(14), height: m.pt(14))
            ) : nil,
            title: title,
            subtitle: shown.subtitle,
            selected: selected,
            contentLeading: DMRowInset.horizontal - DMRowInset.outer,
            trailing: (windows != nil || shared != nil || shown.age != nil) ? AnyView(
                HStack(spacing: m.space.xs) {
                    if let shared { SessionShareBadge(record: shared) }
                    if let age = shown.age {
                        Text(verbatim: age).font(.dm(11)).foregroundStyle(Color.dmMuted)
                    }
                    if let windows {
                        Text(verbatim: "\(windows)").font(.dm(11)).foregroundStyle(Color.dmMuted)
                    }
                }
            ) : nil,
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
