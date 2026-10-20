import Foundation
import XCTest
import DevmachineCore
@testable import DevmachineApp

private final class RecordingFallback: SessionListSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [[String]] = []
    private var storedLocalCalls = 0

    func sessions(for workspace: Workspace, settings: AppSettings) throws -> [TmuxSession] {
        lock.lock()
        defer { lock.unlock() }
        storedCalls.append([workspace.alias])
        return [TmuxSession(name: "from-ssh", windows: 1, harnesses: [])]
    }

    func sessions(
        for workspaces: [Workspace], settings: AppSettings
    ) -> [String: Result<[TmuxSession], any Error>] {
        lock.lock()
        defer { lock.unlock() }
        storedCalls.append(workspaces.map(\.alias))
        var results: [String: Result<[TmuxSession], any Error>] = [:]
        for workspace in workspaces {
            results[workspace.alias] = .success([TmuxSession(name: "from-ssh", windows: 1, harnesses: [])])
        }
        return results
    }

    func localSessions(settings: AppSettings) throws -> LocalSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        storedLocalCalls += 1
        return LocalSessionSnapshot(sessions: [], harnesses: [:])
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    var localCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLocalCalls
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        stored += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class CLIFirstSessionSourceTests: XCTestCase {
    private let acme = Workspace(name: "acme", alias: "acme-devmachine")
    private let beta = Workspace(name: "beta", alias: "beta-devmachine")

    private func source(
        _ runner: SessionsCLIRunner, fallback: RecordingFallback = RecordingFallback()
    ) -> CLIFirstSessionSource {
        CLIFirstSessionSource(
            cli: { DevmachineCLI(executable: "/opt/homebrew/bin/devmachine", runner: runner) },
            fallback: fallback)
    }

    private func session(
        _ name: String, path: String = "/home/acme/acme-web", branch: String = "main",
        age: Int = 60, busy: Bool = false, attention: Bool = false
    ) -> String {
        """
        {"name":"\(name)","windows":1,"path":"\(path)","branch":"\(branch)","age_seconds":\(age),\
        "harnesses":["claude"],"busy":\(busy),"attention":\(attention)}
        """
    }

    private func workspace(_ name: String, sessions: [String] = [], error: String? = nil) -> String {
        let errorField = error.map { #","error":\#($0)"# } ?? ""
        return #"{"name":"\#(name)","machine":"main","sessions":[\#(sessions.joined(separator: ","))]\#(errorField)}"#
    }

    private func output(_ workspaces: String...) -> String {
        #"{"workspaces":[\#(workspaces.joined(separator: ","))]}"#
    }

    func testOneCLICallListsEveryWorkspaceWithItsIndicators() throws {
        let runner = SessionsCLIRunner(result: (output(
            workspace("acme", sessions: [session("checkout-flow", branch: "feature/checkout-flow", age: 10800, busy: true)]),
            workspace("beta", sessions: [session("docs", path: "/home/beta/site", attention: true)])), "", 0))
        let fallback = RecordingFallback()

        let results = source(runner, fallback: fallback).sessions(for: [acme, beta], settings: .empty)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(fallback.calls, [])
        XCTAssertEqual(try results[acme.alias]?.get(), [TmuxSession(
            name: "checkout-flow", windows: 1, harnesses: [.claude],
            indicators: SessionIndicators(
                path: "/home/acme/acme-web", branch: "feature/checkout-flow", ageSeconds: 10800,
                busy: true, attention: false))])
        XCTAssertEqual(try results[beta.alias]?.get(), [TmuxSession(
            name: "docs", windows: 1, harnesses: [.claude],
            indicators: SessionIndicators(
                path: "/home/beta/site", branch: "main", ageSeconds: 60, busy: false, attention: true))])
    }

    func testAWorkspaceWithoutTmuxFailsAloneWithTheSessionListProblem() throws {
        let runner = SessionsCLIRunner(result: (output(
            workspace("acme", sessions: [session("web")]),
            workspace("beta", error: #"{"kind":"tmux-missing","message":"tmux: command not found"}"#)), "", 0))

        let results = source(runner).sessions(for: [acme, beta], settings: .empty)

        XCTAssertEqual(try results[acme.alias]?.get().map(\.name), ["web"])
        XCTAssertThrowsError(try results[beta.alias]?.get()) { error in
            XCTAssertEqual(
                error as? SessionListError,
                SessionListError(problem: .tmuxMissing, stderr: "tmux: command not found"))
        }
    }

    func testCLIErrorKindsMapToTheSSHFailuresTheAppAlreadyShows() {
        let gamma = Workspace(name: "gamma", alias: "gamma-devmachine")
        let runner = SessionsCLIRunner(result: (output(
            workspace("acme", error: #"{"kind":"host-key-rejected","message":"host key changed"}"#),
            workspace("beta", error: #"{"kind":"unreachable","message":"no address answered: 203.0.113.10"}"#),
            workspace("gamma", error: #"{"kind":"other","message":"boom"}"#)), "", 0))

        let results = source(runner).sessions(for: [acme, beta, gamma], settings: .empty)

        XCTAssertThrowsError(try results[acme.alias]?.get()) { error in
            XCTAssertEqual(
                error as? SessionStoreError, SessionStoreError(failure: .hostKeyRejected, stderr: "host key changed"))
        }
        XCTAssertThrowsError(try results[beta.alias]?.get()) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                SessionStoreError(failure: .unreachable, stderr: "no address answered: 203.0.113.10"))
        }
        XCTAssertThrowsError(try results[gamma.alias]?.get()) { error in
            XCTAssertEqual(error as? SessionStoreError, SessionStoreError(failure: .unreachable, stderr: "boom"))
        }
    }

    func testALoginRefusedByTheCLIIsTheRefusedLoginTheSSHPathReports() {
        let message = "the machine refused the login: acme@203.0.113.10: Permission denied (publickey)."
        let runner = SessionsCLIRunner(result: (output(
            workspace("acme", error: #"{"kind":"login-refused","message":"\#(message)"}"#),
            workspace("beta", sessions: [session("web")])), "", 0))

        let results = source(runner).sessions(for: [acme, beta], settings: .empty)

        XCTAssertThrowsError(try results[acme.alias]?.get()) { error in
            XCTAssertEqual((error as? SessionStoreError)?.failure, .authDenied)
            XCTAssertEqual(
                (error as? SessionStoreError)?.stderr.contains("Permission denied (publickey)."), true)
        }
        XCTAssertEqual(try results[beta.alias]?.get().map(\.name), ["web"])
    }

    func testALoginTheAgentHasNotApprovedIsWaitingNotUnreachable() {
        let message = "the SSH agent has not approved the key yet: machine \\\"main\\\" answered on 203.0.113.10"
        let runner = SessionsCLIRunner(result: (output(
            workspace("acme", error: #"{"kind":"login-waiting","message":"\#(message)"}"#)), "", 0))

        let results = source(runner).sessions(for: [acme], settings: .empty)

        XCTAssertThrowsError(try results[acme.alias]?.get()) { error in
            XCTAssertEqual((error as? SessionStoreError)?.failure, .loginWaiting)
        }
    }

    func testAWorkspaceTheCLIDidNotReportIsUnreachable() {
        let runner = SessionsCLIRunner(result: (output(workspace("acme")), "", 0))

        let results = source(runner).sessions(for: [acme, beta], settings: .empty)

        XCTAssertEqual(try results[acme.alias]?.get(), [])
        XCTAssertThrowsError(try results[beta.alias]?.get()) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                SessionStoreError(failure: .unreachable, stderr: "devmachine sessions did not report beta"))
        }
    }

    func testACLIThatFailsOutrightFailsEveryWorkspaceWithoutLoggingInOverSSH() {
        let runner = SessionsCLIRunner(result: ("", "no configuration found", 1))
        let fallback = RecordingFallback()

        let results = source(runner, fallback: fallback).sessions(for: [acme, beta], settings: .empty)

        XCTAssertEqual(fallback.calls, [])
        for alias in [acme.alias, beta.alias] {
            XCTAssertThrowsError(try results[alias]?.get()) { error in
                XCTAssertEqual(
                    error as? SessionStoreError, SessionStoreError(failure: .unreachable, stderr: "no configuration found"))
            }
        }
    }

    func testAnOlderCLISwitchesToSSHForTheRestOfTheRun() throws {
        let runner = SessionsCLIRunner(result: ("", "Error: unknown command \"sessions\" for \"devmachine\"", 1))
        let fallback = RecordingFallback()
        let source = source(runner, fallback: fallback)

        let first = source.sessions(for: [acme, beta], settings: .empty)
        let second = source.sessions(for: [acme], settings: .empty)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(fallback.calls, [[acme.alias, beta.alias], [acme.alias]])
        XCTAssertEqual(try first[beta.alias]?.get().map(\.name), ["from-ssh"])
        XCTAssertEqual(try second[acme.alias]?.get().map(\.name), ["from-ssh"])
    }

    func testAMissingCLIIsLookedForOnceAndSSHServesTheRest() {
        let resolves = CallCounter()
        let fallback = RecordingFallback()
        let source = CLIFirstSessionSource(
            cli: {
                resolves.increment()
                throw DevmachineCLIError.executableNotFound(["/opt/homebrew/bin/devmachine"])
            },
            fallback: fallback)

        _ = source.sessions(for: [acme], settings: .empty)
        _ = source.sessions(for: [beta], settings: .empty)

        XCTAssertEqual(resolves.value, 1)
        XCTAssertEqual(fallback.calls, [[acme.alias], [beta.alias]])
    }

    func testTheCLIIsResolvedOnceAcrossSweeps() {
        let resolves = CallCounter()
        let runner = SessionsCLIRunner(result: (output(workspace("acme")), "", 0))
        let source = CLIFirstSessionSource(
            cli: {
                resolves.increment()
                return DevmachineCLI(executable: "/opt/homebrew/bin/devmachine", runner: runner)
            },
            fallback: RecordingFallback())

        _ = source.sessions(for: [acme], settings: .empty)
        _ = source.sessions(for: [acme], settings: .empty)

        XCTAssertEqual(resolves.value, 1)
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testAnEmptyBranchOrPathIsNoIndicator() throws {
        let runner = SessionsCLIRunner(result: (output(workspace("acme", sessions: [session("web", path: "", branch: "")])), "", 0))

        let sessions = try source(runner).sessions(for: acme, settings: .empty)

        XCTAssertEqual(sessions.first?.indicators?.path, nil)
        XCTAssertEqual(sessions.first?.indicators?.branch, nil)
        XCTAssertEqual(sessions.first?.indicators?.ageSeconds, 60)
    }

    func testAUsableCLIAsksAllWorkspacesAtOnce() {
        let runner = SessionsCLIRunner(result: (output(workspace("acme")), "", 0))

        XCTAssertTrue(source(runner).asksAllAtOnce)
    }

    func testAMissingCLIDoesNotAskAllAtOnce() {
        let source = CLIFirstSessionSource(
            cli: { throw DevmachineCLIError.executableNotFound(["/opt/homebrew/bin/devmachine"]) },
            fallback: RecordingFallback())

        XCTAssertFalse(source.asksAllAtOnce)
    }

    func testAnOlderCLIStopsAskingAllAtOnce() {
        let runner = SessionsCLIRunner(result: ("", "Error: unknown command \"sessions\" for \"devmachine\"", 1))
        let source = source(runner)

        _ = source.sessions(for: [acme], settings: .empty)

        XCTAssertFalse(source.asksAllAtOnce)
    }

    func testTheSSHSourceAsksOneWorkspaceAtATime() {
        XCTAssertFalse(RecordingFallback().asksAllAtOnce)
    }

    func testLocalSessionsStayWithTheFallback() throws {
        let runner = SessionsCLIRunner(result: ("", "", 0))
        let fallback = RecordingFallback()

        _ = try source(runner, fallback: fallback).localSessions(settings: .empty)

        XCTAssertEqual(fallback.localCalls, 1)
        XCTAssertEqual(runner.calls, [])
    }
}
