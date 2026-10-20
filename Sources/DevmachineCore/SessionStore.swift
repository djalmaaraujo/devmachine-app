import Foundation

public struct SessionStore: Sendable {
    private let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    public func sessions(
        for workspace: Workspace,
        processNames: [HarnessID: Set<String>]
    ) throws -> [TmuxSession] {
        let result = try runner.runCapturing(
            executable: "/usr/bin/ssh",
            args: RemoteCommands.sshBaseArgs(alias: workspace.alias) + [RemoteCommands.listSessions],
            environment: RemoteCommands.sshEnvironment()
        )
        if let problem = SessionListProblem.classify(
            alias: workspace.alias, exitCode: result.exitCode, stderr: result.stderr) {
            throw SessionListError(problem: problem, stderr: result.stderr)
        }
        if let failure = SSHFailure.classify(exitCode: result.exitCode, stderr: result.stderr) {
            throw SessionStoreError(failure: failure, stderr: result.stderr)
        }
        return TmuxListParser.parse(result.stdout, processNames: processNames)
    }

    public func run(alias: String, command: String) throws -> String {
        try runner.run(
            executable: "/usr/bin/ssh",
            args: RemoteCommands.sshBaseArgs(alias: alias) + [command],
            environment: RemoteCommands.sshEnvironment()
        )
    }

    public func runCapturing(alias: String, command: String) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        try runner.runCapturing(
            executable: "/usr/bin/ssh",
            args: RemoteCommands.sshBaseArgs(alias: alias) + [command],
            environment: RemoteCommands.sshEnvironment()
        )
    }
}

/// ssh itself failing (exit 255), as opposed to the remote command: the host
/// or the agent is down, and every denied auth counts toward a fail2ban ban.
public enum SSHFailure: Equatable, Sendable {
    case authDenied
    case unreachable
    /// The server answered with a key this Mac does not trust. No login was
    /// tried, so it counts toward no ban, and the host is up.
    case hostKeyRejected
    /// The server accepted the key and the SSH agent has not signed with it
    /// yet: 1Password waits for Touch ID after a wake. The CLI keeps that one
    /// login open and asks nothing more of the server while it waits, so it
    /// counts toward no ban and the host is up.
    case loginWaiting

    public static func classify(exitCode: Int32, stderr: String) -> SSHFailure? {
        guard exitCode == 255 else { return nil }
        // A refused login wins: it counts toward a ban whatever came before.
        if FailureCause.isSSHLoginRefused(stderr) { return .authDenied }
        return HostKeyTrust.isHostKeyRejection(stderr) ? .hostKeyRejected : .unreachable
    }
}

public struct SessionStoreError: Error, Equatable {
    public let failure: SSHFailure
    public let stderr: String

    public init(failure: SSHFailure, stderr: String) {
        self.failure = failure
        self.stderr = stderr
    }
}

/// A session list that failed for one workspace only, so it never stops the
/// sweep or pauses polling the way an ssh-level failure does.
public enum SessionListProblem: Equatable, Sendable {
    /// ssh has no Host entry for the alias: it tried to look the alias up
    /// as a hostname. An entry names its real host or a proxy, never itself.
    case aliasMissing(alias: String)
    /// The login worked and the shell has no tmux (exit 127).
    case tmuxMissing

    public static func classify(alias: String, exitCode: Int32, stderr: String) -> SessionListProblem? {
        if exitCode == 255,
           stderr.lowercased().contains("could not resolve hostname \(alias.lowercased()):") {
            return .aliasMissing(alias: alias)
        }
        if exitCode == 127 { return .tmuxMissing }
        return nil
    }
}

public struct SessionListError: Error, Equatable {
    public let problem: SessionListProblem
    public let stderr: String

    public init(problem: SessionListProblem, stderr: String) {
        self.problem = problem
        self.stderr = stderr
    }
}
