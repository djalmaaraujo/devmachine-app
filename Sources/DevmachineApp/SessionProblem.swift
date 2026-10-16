import Foundation
import DevmachineCore

/// Why a workspace's sessions could not be listed, said plainly with what
/// fixes it, in place of a list that would otherwise just be empty.
enum SessionProblem: Equatable {
    case aliasMissing(alias: String)
    case tmuxMissing(detail: String)
    case loginRefused(detail: String)
    case awaitingSync(detail: String)
    case unreachable(detail: String)
    case hostKeyRejected(detail: String)
    case failed(detail: String)

    init(_ error: Error) {
        if let list = error as? SessionListError {
            switch list.problem {
            case let .aliasMissing(alias): self = .aliasMissing(alias: alias)
            case .tmuxMissing: self = .tmuxMissing(detail: list.stderr)
            }
            return
        }
        if let store = error as? SessionStoreError {
            switch store.failure {
            case .authDenied: self = .loginRefused(detail: store.stderr)
            case .unreachable: self = .unreachable(detail: store.stderr)
            case .hostKeyRejected: self = .hostKeyRejected(detail: store.stderr)
            }
            return
        }
        self = .failed(detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    static let hostKeyCause = "The machine answered with an SSH identity this Mac doesn't trust. "
        + "Review the new key before connecting again."

    var isHostKeyRejected: Bool {
        if case .hostKeyRejected = self { return true }
        return false
    }

    var isAwaitingSync: Bool {
        if case .awaitingSync = self { return true }
        return false
    }

    /// The command that fixes it, when there is one to run on this Mac.
    static let writeAliasesCommand = "devmachine aliases --write"
    static let syncCommand = "devmachine sync"

    /// A new workspace on a machine whose configuration asks for the app's
    /// package but has never synced it: one sync fixes both, while Prepare
    /// would fix only the package, so the sidebar shows one card. A package
    /// not declared at all is not merged: a sync would not add it.
    static func mergesIntoFirstSync(state: MachineReadiness, status: PrepareStatus?, problem: SessionProblem?) -> Bool {
        state == .notApplied && status == nil && problem?.isAwaitingSync == true
    }

    func firstSyncPresentation(workspace: String, machine: String) -> SessionProblemPresentation {
        SessionProblemPresentation(
            title: "\(machine) needs its first sync",
            cause: "\(workspace) has no account on \(machine) yet, and the machine doesn't have the "
                + "devmachine-app package either. One sync sets up both, and the app connects again when it finishes.",
            commands: ["devmachine sync --machine \(machine)"],
            details: awaitingSyncDetail)
    }

    private var awaitingSyncDetail: String {
        if case let .awaitingSync(detail) = self { return detail }
        return ""
    }

    func presentation(workspace: String) -> SessionProblemPresentation {
        switch self {
        case let .aliasMissing(alias):
            return SessionProblemPresentation(
                title: "\(workspace) has no SSH alias yet",
                cause: "ssh found no Host entry named \(alias). The CLI writes one for each workspace "
                    + "into your SSH configuration once you let it.",
                commands: [Self.writeAliasesCommand],
                details: "ssh: Could not resolve hostname \(alias)")
        case let .tmuxMissing(detail):
            return SessionProblemPresentation(
                title: "tmux isn't installed for \(workspace)",
                cause: "The login worked, but the shell has no tmux, which sessions run in. "
                    + "Install it on the machine, then try again.",
                commands: [],
                details: detail.isEmpty ? "tmux: command not found (exit 127)" : detail)
        case let .loginRefused(detail):
            return SessionProblemPresentation(
                title: "Couldn't list \(workspace)'s sessions",
                cause: FailureCause.permissionDenied.summary + " Unlock your SSH agent, then try again.",
                commands: [], details: detail)
        case let .awaitingSync(detail):
            return SessionProblemPresentation(
                title: "\(workspace) isn't set up on its machine yet",
                cause: "A new workspace gets its account at its first sync. Until then the app doesn't try "
                    + "to log in, and it connects when the sync finishes.",
                commands: [Self.syncCommand], details: detail)
        case let .unreachable(detail):
            return SessionProblemPresentation(
                title: "Couldn't list \(workspace)'s sessions",
                cause: FailureCause(message: detail)?.summary ?? FailureCause.unreachable.summary,
                commands: [], details: detail)
        case let .hostKeyRejected(detail):
            return SessionProblemPresentation(
                title: "Couldn't connect to \(workspace)",
                cause: Self.hostKeyCause,
                commands: [], details: detail)
        case let .failed(detail):
            return SessionProblemPresentation(
                title: "Couldn't list \(workspace)'s sessions",
                cause: FailureCause(message: detail)?.summary,
                commands: [], details: detail)
        }
    }
}

/// A sync on its way for a workspace that waits for its first one: the
/// sidebar shows one quiet line under the workspace's name instead of a card
/// that asks for the sync already running.
enum FirstSyncActivity: Equatable {
    case operatorWorking
    case localSync
    case appSync

    var label: String {
        switch self {
        case .operatorWorking: return "Operator is working…"
        case .localSync, .appSync: return "Setting up…"
        }
    }
}

struct SessionProblemPresentation: Equatable {
    let title: String
    let cause: String?
    let commands: [String]
    let details: String
}
