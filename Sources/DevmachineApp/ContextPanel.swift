import SwiftUI
import DevmachineCore

/// What a background row is doing, from the word the engine reports.
enum RunningStatus: Equatable {
    case running, done, failed

    init(_ raw: String) {
        switch raw.lowercased() {
        case "done", "completed", "finished": self = .done
        case "failed", "error", "killed": self = .failed
        default: self = .running
        }
    }
}

enum ContextTab: String, CaseIterable {
    case context
    case preview
    case files
    case git
    case chat

    var title: String {
        switch self {
        case .context: return "Context"
        case .preview: return "Preview"
        case .files: return "Files"
        case .git: return "Git"
        case .chat: return "Chat"
        }
    }
}

struct ContextPanel: View {
    @Environment(\.titleLine) private var titleLine
    @Environment(\.titlebarHeight) private var titlebarHeight
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: ContextStore
    @StateObject private var gitStore = GitStore()
    @ObservedObject var stacks: StackBoardController = .contextSidebar
    @StateObject private var gitContext = ContextGitStatusStore()
    @ObservedObject private var readiness = MachineReadinessStore.shared
    @ObservedObject private var machines = MachinesStore.shared
    @ObservedObject private var shares = SessionShareStore.shared
    @EnvironmentObject private var fileTreeStore: FileTreeStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var stats: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBody
        }
        .task(id: workspaceName) {
            if let workspaceName {
                await WorkspaceMachineData.shared.warm(workspace: workspaceName, stats: stats)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.showsSkeleton)
        .background(Color.dmSidebarBg)
    }

    private var session: (alias: String, name: String)? {
        guard case let .session(alias, name) = model.selection else { return nil }
        return (alias, name)
    }

    /// The live share of the selected session, when this Mac started one.
    private var sharedRecord: SessionShareRecord? {
        guard let session else { return nil }
        return shares.liveShare(alias: session.alias, session: session.name)
    }

    /// Chat is a tab only while the selected session is shared.
    private var tabs: [ContextTab] {
        ContextTab.allCases.filter { $0 != .chat || sharedRecord != nil }
    }

    private var workspaceName: String? {
        guard let alias = session?.alias else { return nil }
        return model.visibleWorkspaces.first(where: { $0.alias == alias })?.name
    }

    /// The workspace the CLI moves the Files tab's files as. A session's alias
    /// always names one, even before the workspace list has loaded.
    private var transferWorkspace: String? {
        guard let alias = session?.alias else { return nil }
        return workspaceName ?? settingsStore.settings?.workspaceName(forAlias: alias)
    }

    /// Where the Files and Git tabs read from: the host for a remote session,
    /// this Mac for a local one.
    private var commandTarget: CommandTarget? {
        model.selectedSessionTarget
    }

    @ViewBuilder
    private var tabBody: some View {
        switch model.contextTab {
        case .context:
            contextBody
        case .preview:
            if let place = model.selectedPreviewPlace {
                PreviewSidebarTab(place: place)
            } else {
                message("No session")
            }
        case .files:
            if let commandTarget {
                FilesTab(store: fileTreeStore, target: commandTarget, workspace: transferWorkspace)
            } else {
                message("No session")
            }
        case .git:
            if let commandTarget {
                GitTab(store: gitStore, target: commandTarget, workspace: workspaceName)
            } else {
                message("No session")
            }
        case .chat:
            if let sharedRecord {
                SessionChatView(record: sharedRecord).id(sharedRecord.id)
            } else {
                message("This session is not shared. Right-click it in the sidebar and choose Share…")
            }
        }
    }

    private var contextBody: some View {
        StackBoardView(controller: stacks, style: .contextSidebar, isVisible: true)
            // An overlay, not a row above the list: a failed poll every 5s on a
            // flaky link would otherwise push the whole list down and back.
            .overlay(alignment: .bottom) {
                if stacks.needsSessionContext, store.state != nil { staleBanner }
            }
            .onChange(of: readyPush, initial: true) { _, push in
                if let push { stacks.setContext(push.facts.values, pending: push.pending) }
            }
            .onChange(of: gitTrigger, initial: true) { _, trigger in
                gitContext.refresh(trigger.needed ? commandTarget : nil, cwd: trigger.cwd, revision: trigger.revision)
            }
            .onAppear { gitContext.appeared() }
            .onChange(of: stacks.needsSessionContext, initial: true) { _, needed in
                model.contextBoardNeedsSessionContext = needed
            }
    }

    private var gitTrigger: GitProbeTrigger {
        GitProbeTrigger(
            target: commandTarget?.key, cwd: store.state?.cwd, revision: store.state?.updatedAt,
            needed: stacks.needsGitContext)
    }

    private var readyPush: ContextPush? {
        guard ContextPushGate.ready(status: store.status, hasState: store.state != nil) else { return nil }
        let pending = ContextPushGate.pendingGitKeys(
            needed: stacks.needsGitContext,
            triggerKey: commandTarget.map { ContextGitStatusStore.key($0, cwd: store.state?.cwd) },
            answeredKey: gitContext.answeredKey)
        return ContextPush(facts: bridgeFacts(git: pending.isEmpty ? gitContext.status : nil), pending: pending)
    }

    private func bridgeFacts(git: ContextGitStatus?) -> SessionContextFacts {
        ContextBridge.facts(
            selection: model.selection, workspaces: model.visibleWorkspaces,
            machineForWorkspace: { readiness.machine(forWorkspace: $0) },
            selfMachine: machines.snapshot?.machines.first(where: \.isSelf)?.name,
            state: store.state, git: git)
    }

    @ViewBuilder
    private var staleBanner: some View {
        if case .failed(let reason) = store.status {
            DMBanner(message: "Couldn't refresh: \(reason)", lineLimit: 2) {
                DMIconButton(systemImage: "arrow.clockwise", size: DMMetrics.baseFontSize, tint: nil) { store.retry() }
                    .help("Try again")
            }
            .background(Color.dmSidebarBg)
        }
    }

    @ViewBuilder
    private func message(_ text: String) -> some View {
        Spacer()
        Text(text)
            .font(.dm(12))
            .foregroundStyle(Color.dmMuted)
            .frame(maxWidth: .infinity)
        Spacer()
    }

    private var header: some View {
        DMSection(
            headerSpacing: 6,
            padding: EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14),
            label: {
                DMTabStrip(
                    tabs: tabs,
                    selection: $model.contextTab,
                    title: { $0.title },
                    fontSize: 11,
                    horizontalPadding: 8,
                    verticalPadding: 3,
                    cornerRadius: DMRadius.row,
                    spacing: 2
                )
            },
            trailing: {
                if let session {
                    TerminalTransportBadge(kind: .remote(alias: session.alias, session: session.name))
                }
                if let commandTarget {
                    DMIconButton(systemImage: "cylinder.split.1x2", size: 12) {
                        model.openSchema()
                    }
                    .help("Database schema")
                }
                DMIconButton(systemImage: "sidebar.right", size: 13, weight: .semibold) {
                    withAnimation(.easeInOut(duration: 0.18)) { model.contextCollapsed = true }
                }
                .help("Close context panel")
            }
        )
        .frame(height: 2 * titleLine)
        // Taller than the title bar: a scroll view whose top touches the
        // title bar's band is stretched up to the window's top edge, and that
        // AppKit view then takes every click meant for this header.
        .frame(height: ContextPanelHeader.height(titleLine: titleLine, titlebar: titlebarHeight), alignment: .top)
    }

}

enum ContextPanelHeader {
    static func height(titleLine: CGFloat, titlebar: CGFloat) -> CGFloat {
        max(2 * titleLine, titlebar > 0 ? titlebar + 1 : 0)
    }
}

private struct ContextPush: Equatable {
    let facts: SessionContextFacts
    let pending: Set<String>
}

private struct GitProbeTrigger: Equatable {
    let target: String?
    let cwd: String?
    let revision: String?
    let needed: Bool
}

struct ContextCollapsedStrip: View {
    @Environment(\.titleLine) private var titleLine
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { model.contextCollapsed = false }
        } label: {
            VStack(spacing: m.pt(18)) {
                Image(systemName: "sidebar.right")
                    .font(.dm(13, weight: .semibold))
                    .foregroundStyle(Color.dmMuted)

                // rotationEffect keeps the pre-rotation layout size, so reserve
                // the rotated text's real footprint (narrow width, tall height)
                // to stop it overlapping the icon above it.
                Text("CONTEXT")
                    .font(.dm(10, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(Color.dmMuted)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: m.pt(14), height: m.pt(78))

                Spacer()
            }
            .padding(.top, titleLine - m.pt(13) / 2)
            .frame(width: m.pt(34))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open context panel")
        .background(Color.dmSidebarBg)
    }
}
