import SwiftUI
import DevmachineCore

/// One task beside the list: what it runs, where, and each run with what
/// it printed.
struct ScheduledDetailView: View {
    @Environment(\.dmMetrics) private var m
    @ObservedObject private var store = ScheduledStore.shared
    let row: ScheduledRow
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var openRun: String?

    private var task: ScheduledTask { row.task }
    private var runs: [ScheduledRun] { store.runs[row.id] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.space.lg) {
                titleBar
                facts
                whatItRuns
                runsSection
            }
            .padding(m.pt(14))
        }
        .onAppear { store.loadRuns(row) }
        .onChange(of: row.id) { _, _ in
            openRun = nil
            store.loadRuns(row)
        }
        .onChange(of: task.lastRun?.id) { _, _ in store.loadRuns(row) }
    }

    private var titleBar: some View {
        VStack(alignment: .leading, spacing: m.space.sm) {
            Text(verbatim: task.name)
                .font(.dm(14, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
            HStack(spacing: m.space.sm) {
                DMButton("Run now", systemImage: "play.fill", size: .small, isLoading: store.busy.contains(row.id)) {
                    store.runNow(row)
                }
                DMButton("Edit", systemImage: "pencil", variant: .outline, size: .small, action: onEdit)
                if task.paused {
                    DMButton("Resume", systemImage: "play", variant: .outline, size: .small) { store.setPaused(row, false) }
                } else if !task.done {
                    DMButton("Pause", systemImage: "pause", variant: .outline, size: .small) { store.setPaused(row, true) }
                }
                DMButton(icon: "trash", label: "Delete", variant: .ghostDanger, size: .small, action: onDelete)
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: m.space.xs) {
            fact("When", "\(task.schedule.describe) (\(task.schedule.timezone))")
            fact("Next", ScheduledStyle.next(task))
            fact("Where", "\(row.workspace.name) · \(task.folder)")
            if task.action.isPrompt {
                fact("Agent", [task.actionLabel, task.action.model.flatMap { $0.isEmpty ? nil : $0 }, task.action.permissionMode]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            }
            fact("Stops after", task.timeout ?? "30m")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: m.space.md) {
            Text(verbatim: label)
                .font(.dm(11, weight: .semibold))
                .foregroundStyle(Color.dmMuted)
                .frame(width: m.pt(76), alignment: .leading)
            Text(verbatim: value)
                .font(.dm(12))
                .foregroundStyle(Color.dmRowText)
                .textSelection(.enabled)
        }
    }

    private var whatItRuns: some View {
        VStack(alignment: .leading, spacing: m.space.xs) {
            Text(task.action.isPrompt ? "Prompt" : "Command")
                .font(.dm(11, weight: .semibold))
                .foregroundStyle(Color.dmMuted)
            Text(verbatim: (task.action.isPrompt ? task.action.prompt : task.action.command) ?? "")
                .font(task.action.isPrompt ? .dm(12) : .dm(12, design: .monospaced))
                .foregroundStyle(Color.dmRowText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(m.space.md)
                .background(Color.dmBand, in: RoundedRectangle(cornerRadius: m.radius.control))
        }
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: m.space.xs) {
            Text("Runs")
                .font(.dm(11, weight: .semibold))
                .foregroundStyle(Color.dmMuted)
            if runs.isEmpty {
                Text("No runs yet. Run now tries it without changing its schedule.")
                    .font(.dm(12))
                    .foregroundStyle(Color.dmMuted)
            }
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: m.space.xs) {
                    runLine(run)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(run) }
                    if openRun == run.id {
                        DMLogView(lines: outputLines(run), title: "Output")
                    }
                }
            }
        }
    }

    private func runLine(_ run: ScheduledRun) -> some View {
        HStack(spacing: m.space.sm) {
            Image(systemName: openRun == run.id ? "chevron.down" : "chevron.right")
                .font(.dm(9))
                .foregroundStyle(Color.dmMuted)
            DMPill(text: run.status.text, color: ScheduledStyle.color(run.status))
            Text(verbatim: run.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.dm(11))
                .foregroundStyle(Color.dmRowText)
            if run.trigger == "manual" {
                Text("Run now").font(.dm(10)).foregroundStyle(Color.dmMuted)
            }
            Spacer()
            if run.status != .running {
                Text(verbatim: ScheduledStyle.duration(run.durationMS))
                    .font(.dm(11))
                    .foregroundStyle(Color.dmMuted)
            }
        }
        .padding(.vertical, m.space.xxs)
        .help(run.message ?? "")
    }

    private func outputLines(_ run: ScheduledRun) -> [String] {
        if !hasOutput(run) { return [run.message ?? "This run printed nothing."] }
        var text = store.logs[run.id] ?? "Reading the output…"
        if let message = run.message, !message.isEmpty { text += "\n▸ \(message)" }
        return text.components(separatedBy: "\n")
    }

    private func hasOutput(_ run: ScheduledRun) -> Bool {
        run.status != .missed && run.status != .skipped
    }

    private func toggle(_ run: ScheduledRun) {
        if openRun == run.id {
            openRun = nil
            return
        }
        openRun = run.id
        if hasOutput(run) { store.loadLog(row, run: run) }
    }
}
