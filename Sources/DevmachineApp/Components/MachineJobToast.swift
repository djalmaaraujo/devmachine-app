import DevmachineCore
import SwiftUI

/// One machine job in the corner stack: the sync question while it waits
/// for an answer, then its step and last line while it runs, with the log
/// a click away, and the result to act on once it is over.
struct MachineJobToast: View {
    struct Actions {
        var start: (Bool) -> Void
        var later: () -> Void
        var cancel: () -> Void
        var retry: () -> Void
        var dismiss: () -> Void
        var toggleLog: () -> Void
        var openFullLog: () -> Void
    }

    let job: MachineJob
    let startsFull: Bool
    var actions: Actions
    @Environment(\.dmMetrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: m.pt(10)) {
            header
            details
            if job.expanded, showsLogButton {
                DMLogView(lines: job.log.shown, title: "Output", collapsedHeight: 160)
            }
            buttons
        }
        .frame(width: m.card.banner, alignment: .leading)
        .dmToastChrome()
        .accessibilityElement(children: .contain)
    }

    private var isOver: Bool {
        switch job.phase {
        case .succeeded, .failed: return true
        default: return false
        }
    }

    private var showsLogButton: Bool {
        switch job.phase {
        case .running, .succeeded, .failed: return true
        default: return false
        }
    }

    private var title: String {
        job.phase == .pending ? "Sync \(job.plan.machine)?" : job.plan.title
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: m.space.md) {
            statusIcon
            Text(verbatim: title)
                .font(.dm(12, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: m.space.xs)
            if isOver {
                DMIconButton(systemImage: "xmark", size: 10, tint: nil, action: actions.dismiss)
                    .dmHelp("Dismiss")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.phase {
        case .pending:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor).font(.dm(12))
        case .queued, .running, .cancelled:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.dm(12))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.dm(12))
        }
    }

    @ViewBuilder
    private var details: some View {
        switch job.phase {
        case .pending:
            pendingDetails
        case .queued:
            muted("Waiting for the job running on \(job.plan.machine)")
        case .running(let step):
            VStack(alignment: .leading, spacing: m.space.xs) {
                muted("Step \(step + 1) of \(max(job.plan.steps.count, step + 1))")
                if let line = lastLine, !line.isEmpty {
                    Text(verbatim: line)
                        .font(.dm(10.5, design: .monospaced))
                        .foregroundStyle(Color.dmRowText.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .succeeded(let summary):
            muted(summary.map { "ok \($0.ok) · changed \($0.changed)" } ?? "Done")
        case .failed(let cause):
            Text(verbatim: cause)
                .font(.dm(11))
                .foregroundStyle(Color.dmRowText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var pendingDetails: some View {
        let request = job.request
        let reasons = request?.reasons.joined(separator: ", ") ?? ""
        let tags = request?.tags.joined(separator: ", ") ?? ""
        VStack(alignment: .leading, spacing: m.space.xs) {
            Text(verbatim: [reasons, tags].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.dm(11))
                .foregroundStyle(Color.dmRowText)
                .fixedSize(horizontal: false, vertical: true)
            if startsFull, !tags.isEmpty {
                muted("A removal or an older CLI needs a full sync.")
            }
        }
    }

    private var lastLine: String? {
        let isSync = job.plan.steps.contains { $0.first == "sync" }
        return JobProgressLine.current(lines: job.log.lines, isSync: isSync, machine: job.plan.machine)
    }

    private func muted(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.dm(11))
            .foregroundStyle(Color.dmMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var buttons: some View {
        switch job.phase {
        case .pending:
            HStack(spacing: m.space.sm) {
                DMButton(startsFull ? "Full sync" : "Sync these", variant: .primary, size: .small) {
                    actions.start(startsFull)
                }
                if !startsFull {
                    Menu("More") {
                        Button("Full sync") { actions.start(true) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.dm(11))
                }
                Spacer(minLength: m.space.sm)
                DMButton("Later", variant: .ghost, size: .small, action: actions.later)
            }
        case .queued:
            HStack(spacing: m.space.sm) {
                Spacer(minLength: 0)
                DMButton("Cancel", variant: .outline, size: .small, action: actions.cancel)
            }
        case .running:
            HStack(spacing: m.space.sm) {
                logButton
                DMButton("Full log", systemImage: "arrow.up.left.and.arrow.down.right", variant: .ghost,
                         size: .small, action: actions.openFullLog)
                Spacer(minLength: m.space.sm)
                DMButton("Cancel", variant: .dangerOutline, size: .small, action: actions.cancel)
            }
        case .succeeded:
            HStack(spacing: m.space.sm) {
                logButton
                Spacer(minLength: 0)
            }
        case .failed:
            FlowLayout(spacing: DMSpace.sm) {
                DMButton("Retry", variant: .primary, size: .small, action: actions.retry)
                logButton
                DMCopyButton(text: job.currentCommand ?? "", title: "Copy command")
                    .disabled(job.currentCommand == nil)
                DMReportBugButton { report }
            }
        case .cancelled:
            EmptyView()
        }
    }

    private var logButton: some View {
        DMButton(job.expanded ? "Hide log" : "Show log", variant: .ghost, size: .small, action: actions.toggleLog)
    }

    @MainActor
    private var report: BugReport {
        var cause = ""
        if case .failed(let text) = job.phase { cause = text }
        return BugReportEnvironment.report(
            title: "\(job.plan.title) failed: \(cause)", stepID: "machine-job",
            command: job.currentCommand ?? "", exitCode: nil, lines: job.log.lines)
    }
}
