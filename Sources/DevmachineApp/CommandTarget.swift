import Foundation
import DevmachineCore

/// Where a panel's commands run. A remote session is read over ssh, in the
/// folder its tmux pane is in; a local one runs here, in the folder the
/// multiplexer reports.
enum CommandTarget: Hashable, Sendable {
    case remote(alias: String, session: String)
    case local(session: String, path: String)

    var key: String {
        switch self {
        case let .remote(alias, session): return "\(alias)/\(session)"
        case let .local(session, path): return "local:\(session):\(path)"
        }
    }

    /// A workspace with no session behind it: the Files window browses a host,
    /// not a pane.
    static func host(alias: String) -> CommandTarget { .remote(alias: alias, session: "") }

    /// What to call this target on screen.
    var label: String {
        switch self {
        case let .remote(alias, session): return session.isEmpty ? alias : session
        case let .local(session, _): return session
        }
    }

    var session: String {
        switch self {
        case let .remote(_, session), let .local(session, _): return session
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

/// Runs one shell command against either side, with the same result shape, so
/// a panel does not have to know which one it is reading.
struct HostRunner: Sendable {
    private let remote: RemoteService
    private let local: CommandRunner

    init(remote: RemoteService = RemoteService(), local: CommandRunner = ProcessRunner()) {
        self.remote = remote
        self.local = local
    }

    /// `command` runs in the target's own folder.
    func runCapturing(_ target: CommandTarget, _ command: String) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        switch target {
        case let .remote(alias, session):
            return try remote.runCapturing(
                alias: alias,
                args: [RemoteCommands.inSessionDirectory(session: session, command: command)])
        case let .local(_, path):
            return try local.runCapturing(
                executable: "/bin/sh",
                args: ["-c", RemoteCommands.inDirectory(path: path, command: command)],
                environment: LocalContext.environment())
        }
    }

    /// The same, but a local folder reaches the shell as an argument, never
    /// spliced into the line. Over ssh the host's tmux names the folder.
    func runCapturingWithFolderArgument(_ target: CommandTarget, _ command: String) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        switch target {
        case .remote:
            return try runCapturing(target, command)
        case let .local(_, path):
            return try local.runCapturing(
                executable: "/bin/sh", args: ["-c", "cd -- \"$1\" && " + command, "sh", path],
                environment: LocalContext.environment())
        }
    }

    /// Puts text where the session is waiting for input, without running it.
    /// One interface, two multiplexers: `tmux send-keys` over there, `zmx send`
    /// here.
    func type(_ text: String, into target: CommandTarget) throws {
        try sendInput(text, into: target, then: nil)
    }

    /// The same, and then the Return key.
    func send(_ text: String, into target: CommandTarget) throws {
        try sendInput(text, into: target, then: Zmx.enterText)
    }

    private func sendInput(_ text: String, into target: CommandTarget, then enter: String?) throws {
        switch target {
        case let .remote(alias, session):
            let command = enter == nil
                ? RemoteCommands.typeKeys(session: session, text: text)
                : RemoteCommands.sendKeys(session: session, text: text)
            _ = try remote.run(alias: alias, args: [command])
        case let .local(session, _):
            guard let zmx = LocalTools.zmxPath() else { return }
            let socketDirectory = Zmx.socketDirectory()
            let name = Zmx.sessionName(from: session, socketDirectory: socketDirectory)
            let environment = ["ZMX_DIR": socketDirectory]
            _ = try local.run(
                executable: zmx, args: Zmx.sendArguments(name: name, text: text),
                environment: environment)
            if let enter {
                _ = try local.run(
                    executable: zmx, args: Zmx.sendArguments(name: name, text: enter),
                    environment: environment)
            }
        }
    }

    /// A command that names the folder it works on, so it does not need one.
    func runCapturingAnywhere(_ target: CommandTarget, _ command: String) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        switch target {
        case let .remote(alias, _):
            return try remote.runCapturing(alias: alias, args: [command])
        case .local:
            return try local.runCapturing(
                executable: "/bin/sh", args: ["-c", command],
                environment: LocalContext.environment())
        }
    }
}
