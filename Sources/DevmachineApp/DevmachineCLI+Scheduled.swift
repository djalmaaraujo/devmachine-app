import Foundation
import DevmachineCore

/// `devmachine scheduled`: tasks that run on their own in a workspace. Each
/// workspace keeps its own tasks; the CLI asks them all at once.
extension DevmachineCLI {
    func scheduledList() throws -> [ScheduledWorkspace] {
        let result = try scheduled(["--format", "json", "scheduled", "list"])
        return try ScheduledJSON.decodeList(Data(result.stdout.utf8))
    }

    func scheduledHarnesses() throws -> [ScheduledHarness] {
        let result = try scheduled(["--format", "json", "scheduled", "harnesses"])
        return try ScheduledJSON.decodeHarnesses(Data(result.stdout.utf8))
    }

    /// Runs `add` or `edit` as `ScheduledDraft.arguments` built it. A first
    /// task in a workspace also sets up the package and syncs the machine,
    /// which can take a minute.
    func scheduledSave(_ arguments: [String]) throws -> ScheduledTask {
        let result = try scheduled(arguments)
        return try ScheduledJSON.decodeSaved(Data(result.stdout.utf8))
    }

    func scheduledPause(_ id: String, workspace: String) throws {
        _ = try scheduled(["--format", "json", "scheduled", "pause", id, "--workspace", workspace])
    }

    func scheduledResume(_ id: String, workspace: String) throws {
        _ = try scheduled(["--format", "json", "scheduled", "resume", id, "--workspace", workspace])
    }

    /// `--yes`: the app already asked.
    func scheduledRemove(_ id: String, workspace: String) throws {
        _ = try scheduled(["--format", "json", "scheduled", "rm", id, "--workspace", workspace, "--yes"])
    }

    /// Starts the task now and returns the run's id; the run goes on in the
    /// workspace after this returns.
    func scheduledRunNow(_ id: String, workspace: String) throws -> String {
        let result = try scheduled(["--format", "json", "scheduled", "run", id, "--workspace", workspace])
        return try ScheduledJSON.decodeRunID(Data(result.stdout.utf8))
    }

    func scheduledRuns(_ id: String, workspace: String) throws -> [ScheduledRun] {
        let result = try scheduled(["--format", "json", "scheduled", "runs", id, "--workspace", workspace])
        return try ScheduledJSON.decodeRuns(Data(result.stdout.utf8))
    }

    func scheduledLog(_ id: String, run: String, workspace: String) throws -> String {
        try scheduled(["scheduled", "log", id, run, "--workspace", workspace]).stdout
    }

    private func scheduled(_ args: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let result = try runner.runCapturing(executable: executable, args: args, environment: environment())
        if result.exitCode != 0, result.stderr.contains("unknown command \"scheduled\"") {
            throw DevmachineCLIError.needsNewerCLI("scheduled")
        }
        try requireSuccess((result.stdout, Self.withoutErrorPrefix(result.stderr), result.exitCode))
        return result
    }

    static func withoutErrorPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("error: ") ? String(trimmed.dropFirst("error: ".count)) : trimmed
    }
}
