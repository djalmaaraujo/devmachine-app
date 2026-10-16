import SwiftUI
import DevmachineCore

/// The card's words for each state, kept apart from the view so they are
/// tested.
enum MachineReadinessContent {
    static let prepareTitle = "Prepare"

    static func title(machine: String, state: MachineReadiness, status: PrepareStatus?) -> String {
        switch status {
        case .running: return "Preparing \(machine)…"
        case .succeeded: return "\(machine) is ready"
        case .failed, nil: break
        }
        if case .outdated = state { return "\(machine)'s devmachine-app package is out of date" }
        return "\(machine) isn't ready for the app yet"
    }

    static let missingBody = "The app reads this machine's stats, logs and session context through the "
        + "devmachine-app package. Prepare adds it and applies only that package."

    static let oldCLIBody = "Your devmachine CLI can't prepare a machine from here yet (it needs "
        + "\(MachinePrepare.minimumCLIVersion) or newer). Update the CLI first, or run this in a terminal:"

    static let outdatedBody = "It comes from an older packages release than this app needs. The release "
        + "is pinned once for every machine, so the app doesn't move it for you. Run this in a terminal:"

    static let updateCLITitle = "Update the CLI first"
    static let showInCornerTitle = "Show in corner"
    static let retryTitle = "Try again"
    static let preparingBody = "Preparing… the card in the corner shows the log"

    static func compactLine(machine: String, status: PrepareStatus) -> String {
        switch status {
        case .running: return "Preparing \(machine)…"
        case .succeeded: return "\(machine) is ready"
        case .failed: return "Prepare failed"
        }
    }

    static func commands(machine: String, state: MachineReadiness, declared: Bool) -> [String] {
        if case .outdated = state { return MachinePrepare.outdatedCommands(machine: machine) }
        return MachinePrepare.manualCommands(machine: machine, declared: declared)
    }
}

/// One machine that is missing what the app runs on it: a calm card with
/// one Prepare button. Prepare runs as a job in the corner, which holds its
/// log; the card says where it stands and offers Retry when it fails.
/// `compact` is the sidebar's version.
struct MachineReadinessCard: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: MachineReadinessStore
    let machine: String
    var compact = false

    private var state: MachineReadiness { store.state(for: machine) }
    private var status: PrepareStatus? { store.prepareStatus(machine) }

    var body: some View {
        Group {
            if compact, let status {
                compactStatusLine(status)
            } else {
                VStack(alignment: .leading, spacing: compact ? m.space.sm : m.space.md) {
                    header
                    content
                }
            }
        }
        .padding(compact ? m.space.md : m.space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The sidebar is too narrow for more: a running, failed or finished
    /// Prepare is one line there.
    private func compactStatusLine(_ status: PrepareStatus) -> some View {
        HStack(spacing: m.space.sm) {
            icon
            Text(verbatim: MachineReadinessContent.compactLine(machine: machine, status: status))
                .font(.dm(11.5, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            switch status {
            case .running:
                EmptyView()
            case .failed(_, inCorner: true):
                DMButton(MachineReadinessContent.showInCornerTitle, variant: .link, size: .small) {
                    store.showPrepareInCorner(machine)
                }
            case .failed:
                DMButton(MachineReadinessContent.retryTitle, variant: .link, size: .small) {
                    store.retryPrepare(machine)
                }
            case .succeeded:
                DMButton(icon: "xmark", label: "Dismiss", size: .small) { store.dismissPrepare(machine) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: m.space.sm) {
            icon
            Text(verbatim: MachineReadinessContent.title(machine: machine, state: state, status: status))
                .font(.dm(compact ? 11.5 : 12.5, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if status == .succeeded {
                DMButton(icon: "xmark", label: "Dismiss", size: .small) { store.dismissPrepare(machine) }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed where compact:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: "shippingbox").foregroundStyle(Color.dmMuted)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .running:
            paragraph(MachineReadinessContent.preparingBody)
        case .succeeded:
            EmptyView()
        case let .failed(error, inCorner):
            DMErrorStateView(state: error, retry: { store.retryPrepare(machine) })
                .frame(maxWidth: .infinity)
            if inCorner {
                DMButton(MachineReadinessContent.showInCornerTitle, variant: .link, size: .small) {
                    store.showPrepareInCorner(machine)
                }
            }
        case nil:
            idle
        }
    }

    @ViewBuilder
    private var idle: some View {
        if state.needsPrepare, store.canPrepareInApp {
            paragraph(MachineReadinessContent.missingBody)
            DMButton(MachineReadinessContent.prepareTitle, systemImage: "wrench.and.screwdriver", size: .small) {
                store.prepare(machine)
            }
        } else if state.needsPrepare {
            paragraph(MachineReadinessContent.oldCLIBody)
            DMCommandBlock(MachineReadinessContent.commands(
                machine: machine, state: state, declared: store.isDeclared(machine)), wraps: compact)
            DMButton(MachineReadinessContent.updateCLITitle, variant: .link, size: .small) {
                model.openSettings(.about)
            }
        } else if case .outdated = state {
            paragraph(MachineReadinessContent.outdatedBody)
            DMCommandBlock(
                MachineReadinessContent.commands(machine: machine, state: state, declared: true), wraps: compact)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.dm(compact ? 10.5 : 11.5))
            .foregroundStyle(Color.dmMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A workspace paused after an ssh failure, in the sidebar under its name:
/// one line that says why nothing is checked, and Try again.
struct PollPauseSidebarCard: View {
    @Environment(\.dmMetrics) private var m
    let notice: String
    let reason: PollPause.Reason
    let retry: () -> Void

    static let retryTitle = "Try again"

    var body: some View {
        HStack(spacing: m.space.sm) {
            Image(systemName: reason == .unreachable ? "wifi.exclamationmark" : "pause.circle")
                .foregroundStyle(.orange)
            Text(verbatim: notice)
                .font(.dm(11.5, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            DMButton(Self.retryTitle, variant: .outline, size: .small, action: retry)
        }
        .padding(m.space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A workspace whose sessions could not be listed: the reason and the fix,
/// where the list would otherwise be empty.
struct SessionProblemView: View {
    @Environment(\.dmMetrics) private var m
    let presentation: SessionProblemPresentation
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: m.space.sm) {
            DMErrorStateView(
                state: DMErrorState(
                    title: presentation.title, cause: presentation.cause, details: presentation.details),
                retry: retry)
                .frame(maxWidth: .infinity)
            if !presentation.commands.isEmpty {
                DMCommandBlock(presentation.commands, wraps: true)
            }
        }
        .padding(m.space.md)
    }
}

/// One quiet line under a workspace's name while its first sync is on its
/// way: the sync takes minutes, and the card that asks for it would only
/// ask for what is already running.
struct FirstSyncActivityRow: View {
    @Environment(\.dmMetrics) private var m
    let activity: FirstSyncActivity

    var body: some View {
        HStack(spacing: m.space.xs) {
            ProgressView().controlSize(.mini)
            Text(activity.label)
                .font(.dm(11))
                .foregroundStyle(Color.dmMuted)
        }
        .padding(EdgeInsets(top: 2, leading: 10, bottom: 6, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("The workspace gets its account when the sync finishes, and its sessions show up then.")
        .accessibilityElement(children: .combine)
    }
}
