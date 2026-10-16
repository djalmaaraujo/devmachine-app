import SwiftUI
import DevmachineCore

/// The Scheduled page: every workspace's scheduled tasks, the next to run
/// first, with a task's runs and output beside the list.
struct ScheduledView: View {
    @Environment(\.dmMetrics) private var m
    @ObservedObject private var store = ScheduledStore.shared
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var selected: String?
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
                selected = saved
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
                    if selected == row.id { selected = nil }
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
            DMButton("New task", systemImage: "plus", size: .small) { sheet = .new }
                .disabled(store.workspaces.isEmpty)
        }
        .padding(.horizontal, m.pt(14))
        .padding(.top, m.pt(10))
        .padding(.bottom, m.space.sm)
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
                    if let id = selected, let row = store.row(id) {
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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(searchedRows.enumerated()), id: \.element.id) { index, row in
                    DMTableRow(index: index) {
                        ScheduledRowView(row: row, isSelected: selected == row.id, isBusy: store.busy.contains(row.id),
                                         menu: { rowMenu(row) })
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = selected == row.id ? nil : row.id }
                    .contextMenu { rowMenu(row) }
                }
            }
            .padding(.horizontal, m.pt(6))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func rowMenu(_ row: ScheduledRow) -> some View {
        Button("Run now") { store.runNow(row); selected = row.id }
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
            DMButton("New task", systemImage: "plus", size: .small, action: onNew)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ScheduledRowView<Menu: View>: View {
    @Environment(\.dmMetrics) private var m
    let row: ScheduledRow
    let isSelected: Bool
    let isBusy: Bool
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        HStack(spacing: m.pt(10)) {
            Circle()
                .fill(ScheduledStyle.color(row.task.lastRun?.status))
                .frame(width: m.pt(7), height: m.pt(7))
                .help(row.task.lastRun.map { "Last run \($0.status.text)" } ?? "Not run yet")
            VStack(alignment: .leading, spacing: m.space.xxs) {
                Text(verbatim: row.task.name)
                    .font(.dm(12, weight: .semibold))
                    .foregroundStyle(Color.dmRowText)
                    .lineLimit(1)
                Text(verbatim: "\(row.task.schedule.describe) · \(row.workspace.name) · \(row.task.folder)")
                    .font(.dm(11))
                    .foregroundStyle(Color.dmMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: m.space.md)
            DMPill(text: row.task.actionLabel, color: row.task.action.isPrompt ? .purple : Color.dmRowText)
            Text(verbatim: ScheduledStyle.next(row.task))
                .font(.dm(11))
                .foregroundStyle(row.task.paused || row.task.done ? Color.dmMuted : Color.dmRowText)
                .frame(width: m.pt(120), alignment: .trailing)
            if isBusy {
                ProgressView().controlSize(.small)
            }
            SwiftUI.Menu { menu() } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.dmMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, m.pt(8))
        .padding(.vertical, m.pt(8))
        .background(isSelected ? Color.dmSelection : Color.clear, in: RoundedRectangle(cornerRadius: m.radius.control))
        .opacity(row.task.paused || row.task.done ? 0.6 : 1)
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
