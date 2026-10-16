import SwiftUI
import DevmachineCore

/// The Scheduled page: every workspace's scheduled tasks, the next to run
/// first, with a task's runs and output beside the list.
struct ScheduledView: View {
    @Environment(\.dmMetrics) private var m
    @ObservedObject private var store = ScheduledStore.shared
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var sheet: ScheduledSheetRequest?
    @State private var confirmDelete: ScheduledRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.dmContentBg)
        .onAppear { store.appear() }
        .sheet(item: $sheet) { request in
            ScheduledTaskSheet(request: request) { saved in
                store.selectedID = saved
            }
            .environmentObject(model)
        }
        .confirmationDialog(
            confirmDelete.map { "Delete \u{201C}\($0.task.name)\u{201D}?" } ?? "",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = confirmDelete {
                    store.delete(row)
                    if store.selectedID == row.id { store.selectedID = nil }
                }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text(verbatim: "The task and the record of its runs go away from its workspace.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })
        ) {
            Button("OK", role: .cancel) { store.actionError = nil }
        } message: {
            Text(verbatim: store.actionError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: m.pt(10)) {
            Text("Scheduled")
                .font(.dm(13, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
            DMSearchField(prompt: "Search tasks", text: $searchText)
                .frame(maxWidth: m.pt(240))
                .padding(.horizontal, m.space.md)
                .padding(.vertical, m.pt(5))
                .background(Color.dmSelection, in: RoundedRectangle(cornerRadius: m.radius.control, style: .continuous))
            Spacer()
            DMAgeLabel(since: store.refreshedAt, staleAfter: 60, isRefreshing: store.isLoading)
            DMIconButton(systemImage: "arrow.clockwise", size: DMMetrics.baseFontSize, tint: nil) { store.refresh() }
                .help("Refresh")
            DMButton("New task", systemImage: "plus") { sheet = .new }
                .disabled(store.workspaces.isEmpty)
                .demoClickTarget("scheduled:new")
        }
        .padding(.horizontal, m.pt(18))
        .padding(.top, m.pt(12))
        .padding(.bottom, m.space.md)
    }

    private var searchedRows: [ScheduledRow] {
        RowSearch.filter(store.rows, query: searchText) { row in
            [row.task.name, row.workspace.name, row.task.folder, row.task.schedule.describe, row.task.actionLabel]
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.loadError, store.workspaces.isEmpty {
            DMStatusView(kind: .failed(title: "Couldn't read the scheduled tasks", message: error, retry: { store.refresh() }))
        } else if !store.hasLoaded {
            DMStatusView(kind: .loading("Asking every workspace…"))
        } else if store.rows.isEmpty {
            VStack(spacing: m.space.lg) {
                workspaceErrors
                Spacer()
                ScheduledEmptyState { sheet = .new }
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                workspaceErrors
                HStack(spacing: 0) {
                    list
                    if let id = store.selectedID, let row = store.row(id) {
                        ScheduledDetailView(
                            row: row,
                            onEdit: { sheet = .edit(row) },
                            onDelete: { confirmDelete = row })
                            .frame(width: m.pt(420))
                            .background(Color.dmSidebarBg.opacity(0.5))
                            .transition(.move(edge: .trailing))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceErrors: some View {
        ForEach(store.failedWorkspaces) { w in
            DMBanner(message: "\(w.name): \(w.error?.message ?? "")", lineLimit: 2) { EmptyView() }
        }
    }

    /// The rows by workspace, a workspace placed where its next task falls.
    private var groups: [(workspace: ScheduledWorkspace, rows: [ScheduledRow])] {
        var order: [String] = []
        var byName: [String: (ScheduledWorkspace, [ScheduledRow])] = [:]
        for row in searchedRows {
            if byName[row.workspace.name] == nil {
                order.append(row.workspace.name)
                byName[row.workspace.name] = (row.workspace, [])
            }
            byName[row.workspace.name]?.1.append(row)
        }
        return order.compactMap { byName[$0].map { (workspace: $0.0, rows: $0.1) } }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: m.space.xl) {
                ForEach(groups, id: \.workspace.name) { group in
                    VStack(alignment: .leading, spacing: m.space.sm) {
                        HStack(spacing: m.space.sm) {
                            Image(systemName: "server.rack")
                                .font(.dm(10))
                            Text(verbatim: group.workspace.name.uppercased())
                                .font(.dm(11, weight: .semibold))
                                .kerning(0.8)
                            Text(verbatim: "· \(group.workspace.machine)")
                                .font(.dm(11))
                        }
                        .foregroundStyle(Color.dmMuted)
                        .padding(.leading, m.space.xs)
                        ForEach(group.rows) { row in
                            ScheduledCard(
                                row: row, isSelected: store.selectedID == row.id, isBusy: store.busy.contains(row.id),
                                menu: { rowMenu(row) })
                                .demoClickTarget("scheduled:\(row.id)")
                                .contentShape(Rectangle())
                                .onTapGesture { store.selectedID = store.selectedID == row.id ? nil : row.id }
                                .contextMenu { rowMenu(row) }
                        }
                    }
                }
                if groups.isEmpty {
                    Text(verbatim: "No task matches \u{201C}\(searchText)\u{201D}.")
                        .font(.dm(12))
                        .foregroundStyle(Color.dmMuted)
                }
            }
            .padding(.horizontal, m.pt(18))
            .padding(.vertical, m.space.md)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func rowMenu(_ row: ScheduledRow) -> some View {
        Button("Run now") { store.runNow(row); store.selectedID = row.id }
        Button("Edit…") { sheet = .edit(row) }
        if row.task.paused {
            Button("Resume") { store.setPaused(row, false) }
        } else if !row.task.done {
            Button("Pause") { store.setPaused(row, true) }
        }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = row }
    }
}

enum ScheduledSheetRequest: Identifiable {
    case new
    case edit(ScheduledRow)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let row): return row.id
        }
    }
}

private struct ScheduledEmptyState: View {
    @Environment(\.dmMetrics) private var m
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: m.space.md) {
            Image(systemName: "clock")
                .font(.system(size: m.pt(34), weight: .light))
                .foregroundStyle(Color.dmMuted)
            Text("No scheduled tasks yet.")
                .font(.dm(13, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
            Text("A task runs a command, or a prompt for Claude or Codex, in a workspace on a schedule. It runs there with this Mac off.")
                .font(.dm(12))
                .foregroundStyle(Color.dmMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: m.pt(380))
            DMButton("New task", systemImage: "plus", action: onNew)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ScheduledCard<Menu: View>: View {
    @Environment(\.dmMetrics) private var m
    let row: ScheduledRow
    let isSelected: Bool
    let isBusy: Bool
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    private var task: ScheduledTask { row.task }
    private var resting: Bool { task.paused || task.done }
    private var tint: Color { task.action.isPrompt ? .accentColor : Color.dmRowText }

    var body: some View {
        HStack(spacing: m.space.lg) {
            Image(systemName: task.action.isPrompt ? "sparkles" : "terminal")
                .font(.dm(14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: m.pt(34), height: m.pt(34))
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: m.pt(DMRadius.tile), style: .continuous))
            VStack(alignment: .leading, spacing: m.space.xs) {
                HStack(spacing: m.space.sm) {
                    Text(verbatim: task.name)
                        .font(.dm(13, weight: .semibold))
                        .foregroundStyle(Color.dmRowText)
                        .lineLimit(1)
                    DMKindLabel(text: task.actionLabel.uppercased())
                    if task.paused { DMKindLabel(text: "PAUSED") }
                    if task.done { DMKindLabel(text: "DONE") }
                }
                HStack(spacing: m.space.xs) {
                    Image(systemName: "clock").font(.dm(10))
                    Text(verbatim: task.schedule.describe)
                    Text(verbatim: "·")
                    Image(systemName: "folder").font(.dm(10))
                    Text(verbatim: task.folder).lineLimit(1).truncationMode(.middle)
                }
                .font(.dm(11.5))
                .foregroundStyle(Color.dmMuted)
            }
            Spacer(minLength: m.space.md)
            VStack(alignment: .trailing, spacing: m.space.xs) {
                Text(verbatim: ScheduledStyle.next(task))
                    .font(.dm(12, weight: .medium))
                    .foregroundStyle(resting ? Color.dmMuted : Color.dmRowText)
                lastRun
            }
            if isBusy {
                ProgressView().controlSize(.small)
            }
            SwiftUI.Menu { menu() } label: {
                Image(systemName: "ellipsis")
                    .font(.dm(13, weight: .semibold))
                    .foregroundStyle(Color.dmMuted)
                    .frame(width: m.pt(28), height: m.pt(28))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, m.space.lg)
        .padding(.vertical, m.pt(10))
        .dmSurface(
            isSelected ? Color.dmSelection : (hovering ? Color.dmHover : Color.dmBand),
            radius: DMRadius.tile,
            stroke: isSelected ? Color.accentColor.opacity(0.55) : .dmStroke,
            lineWidth: isSelected ? 1 : 0.5)
        .opacity(resting ? 0.7 : 1)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var lastRun: some View {
        if let run = task.lastRun {
            HStack(spacing: m.space.xs) {
                Circle()
                    .fill(ScheduledStyle.color(run.status))
                    .frame(width: m.pt(DMIconSize.dot) - 1, height: m.pt(DMIconSize.dot) - 1)
                Text(verbatim: "\(run.status.text.capitalized) \(ScheduledStyle.relative(run.startedAt))")
            }
            .font(.dm(11))
            .foregroundStyle(Color.dmMuted)
        } else {
            Text("Not run yet").font(.dm(11)).foregroundStyle(Color.dmMuted)
        }
    }
}

enum ScheduledStyle {
    static func color(_ status: ScheduledRunStatus?) -> Color {
        switch status {
        case .succeeded: return .green
        case .running: return .blue
        case .failed, .error, .timeout: return .red
        case .missed, .skipped: return .orange
        case .other, nil: return Color.dmMuted.opacity(0.5)
        }
    }

    static func next(_ task: ScheduledTask, now: Date = Date()) -> String {
        if task.paused { return "Paused" }
        if task.done { return "Done" }
        guard let next = task.nextRunAt else { return "—" }
        return "Next " + relative(next, now: now)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}
