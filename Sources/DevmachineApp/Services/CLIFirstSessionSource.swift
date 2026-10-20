import Foundation
import os
import DevmachineCore

/// Lists remote sessions through `devmachine sessions`, one CLI call for the
/// whole sweep. A CLI without that command, or no CLI at all, hands the rest
/// of the app run to the ssh path; the next launch tries the CLI again.
struct CLIFirstSessionSource: SessionListSource {
    private struct State: Sendable {
        var useFallback = false
        var cli: DevmachineCLI?
    }

    private let resolveCLI: @Sendable () throws -> DevmachineCLI
    private let fallback: any SessionListSource
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        cli: @escaping @Sendable () throws -> DevmachineCLI = { try DevmachineCLI.resolve() },
        fallback: any SessionListSource = CommandSessionSource()
    ) {
        self.resolveCLI = cli
        self.fallback = fallback
    }

    var asksAllAtOnce: Bool { currentCLI() != nil }

    func sessions(for workspace: Workspace, settings: AppSettings) throws -> [TmuxSession] {
        guard let result = sessions(for: [workspace], settings: settings)[workspace.alias] else {
            throw Self.notReported(workspace)
        }
        return try result.get()
    }

    func sessions(
        for workspaces: [Workspace], settings: AppSettings
    ) -> [String: Result<[TmuxSession], any Error>] {
        guard let cli = currentCLI() else {
            return fallback.sessions(for: workspaces, settings: settings)
        }
        let list: CLISessionList
        do {
            list = try cli.sessions(workspaces: workspaces.map(\.name))
        } catch DevmachineCLIError.needsNewerCLI {
            state.withLock { $0.useFallback = true }
            return fallback.sessions(for: workspaces, settings: settings)
        } catch {
            // Not the ssh fallback: that would log into every workspace every
            // 5 s with no pause check, which is how a machine bans the Mac.
            let failure = SessionStoreError(failure: .unreachable, stderr: error.localizedDescription)
            return results(for: workspaces) { _ in .failure(failure) }
        }
        var reported: [String: CLISessionWorkspace] = [:]
        for entry in list.workspaces where reported[entry.name] == nil {
            reported[entry.name] = entry
        }
        return results(for: workspaces) { workspace in
            guard let entry = reported[workspace.name] else { return .failure(Self.notReported(workspace)) }
            return Self.result(of: entry)
        }
    }

    func localSessions(settings: AppSettings) throws -> LocalSessionSnapshot {
        try fallback.localSessions(settings: settings)
    }

    private func currentCLI() -> DevmachineCLI? {
        state.withLock { state in
            if state.useFallback { return nil }
            if let cli = state.cli { return cli }
            guard let cli = try? resolveCLI() else {
                state.useFallback = true
                return nil
            }
            state.cli = cli
            return cli
        }
    }

    private func results(
        for workspaces: [Workspace], _ make: (Workspace) -> Result<[TmuxSession], any Error>
    ) -> [String: Result<[TmuxSession], any Error>] {
        var results: [String: Result<[TmuxSession], any Error>] = [:]
        for workspace in workspaces {
            results[workspace.alias] = make(workspace)
        }
        return results
    }

    private static func result(of entry: CLISessionWorkspace) -> Result<[TmuxSession], any Error> {
        guard let error = entry.error else {
            return .success(entry.sessions.map(session))
        }
        switch error.kind {
        case "tmux-missing":
            return .failure(SessionListError(problem: .tmuxMissing, stderr: error.message))
        case "host-key-rejected":
            return .failure(SessionStoreError(failure: .hostKeyRejected, stderr: error.message))
        case "login-refused":
            return .failure(SessionStoreError(failure: .authDenied, stderr: error.message))
        case "login-waiting":
            return .failure(SessionStoreError(failure: .loginWaiting, stderr: error.message))
        default:
            return .failure(SessionStoreError(failure: .unreachable, stderr: error.message))
        }
    }

    private static func session(_ session: CLISession) -> TmuxSession {
        TmuxSession(
            name: session.name,
            windows: session.windows,
            harnesses: Set(session.harnesses.map(HarnessID.init(rawValue:))),
            indicators: SessionIndicators(
                path: session.path.isEmpty ? nil : session.path,
                branch: session.branch.isEmpty ? nil : session.branch,
                ageSeconds: session.ageSeconds,
                busy: session.busy,
                attention: session.attention))
    }

    private static func notReported(_ workspace: Workspace) -> SessionStoreError {
        SessionStoreError(failure: .unreachable, stderr: "devmachine sessions did not report \(workspace.name)")
    }
}
