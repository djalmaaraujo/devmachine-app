import Foundation
import DevmachineCore

/// One task and the workspace it lives in: a task id is only unique there.
struct ScheduledRow: Identifiable, Equatable {
    let workspace: ScheduledWorkspace
    let task: ScheduledTask

    var id: String { "\(workspace.name)/\(task.id)" }
}

/// What the Scheduled page shows and does. Every call goes to
/// `devmachine scheduled`, off the main thread.
@MainActor
final class ScheduledStore: ObservableObject {
    static let shared = ScheduledStore()

    @Published private(set) var workspaces: [ScheduledWorkspace] = []
    @Published private(set) var harnesses: [ScheduledHarness] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var refreshedAt: Date?
    @Published var actionError: String?
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var runs: [String: [ScheduledRun]] = [:]
    @Published private(set) var logs: [String: String] = [:]
    /// The task shown beside the list, and the run whose output is open;
    /// kept here so the page shows them again when it comes back.
    @Published var selectedID: String?
    @Published var openRunID: String?

    private let makeCLI: @Sendable () throws -> DevmachineCLI
    private var polling: Set<String> = []
    private var isDemo = false

    init(makeCLI: @escaping @Sendable () throws -> DevmachineCLI = { try DevmachineCLI.resolve() }) {
        self.makeCLI = makeCLI
    }

    /// Tasks across every workspace: the next to run first, paused and done
    /// ones last.
    var rows: [ScheduledRow] {
        workspaces.flatMap { w in w.tasks.map { ScheduledRow(workspace: w, task: $0) } }
            .sorted { a, b in
                switch (a.task.nextRunAt, b.task.nextRunAt) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return (a.task.name, a.id) < (b.task.name, b.id)
                }
            }
    }

    var failedWorkspaces: [ScheduledWorkspace] { workspaces.filter { $0.error != nil } }

    func row(_ id: String) -> ScheduledRow? { rows.first { $0.id == id } }

    func appear() {
        if !hasLoaded && !isLoading { refresh() }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                async let list = cli { try $0.scheduledList() }
                async let agents = cli { try $0.scheduledHarnesses() }
                workspaces = try await list
                harnesses = (try? await agents) ?? harnesses
                loadError = nil
                refreshedAt = Date()
            } catch {
                loadError = error.localizedDescription
            }
            hasLoaded = true
        }
    }

    func harness(_ name: String) -> ScheduledHarness? { harnesses.first { $0.name == name } }

    /// Saves the form. On a workspace without the package, `add --yes` sets
    /// it up and syncs the machine first.
    func save(_ draft: ScheduledDraft, editing: String?, allowDangerous: Bool) async throws -> ScheduledTask {
        let args = draft.arguments(editing: editing, allowDangerous: allowDangerous)
        let task = try await cli { try $0.scheduledSave(args) }
        refresh()
        return task
    }

    func runNow(_ row: ScheduledRow) {
        busy.insert(row.id)
        Task {
            defer { busy.remove(row.id) }
            do {
                let runID = try await cli { try $0.scheduledRunNow(row.task.id, workspace: row.workspace.name) }
                poll(row, until: runID)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func setPaused(_ row: ScheduledRow, _ paused: Bool) {
        perform(row) { cli in
            if paused {
                try cli.scheduledPause(row.task.id, workspace: row.workspace.name)
            } else {
                try cli.scheduledResume(row.task.id, workspace: row.workspace.name)
            }
        }
    }

    func delete(_ row: ScheduledRow) {
        perform(row) { cli in try cli.scheduledRemove(row.task.id, workspace: row.workspace.name) }
    }

    func loadRuns(_ row: ScheduledRow) {
        guard !isDemo else { return }
        Task {
            do {
                runs[row.id] = try await cli { try $0.scheduledRuns(row.task.id, workspace: row.workspace.name) }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func loadLog(_ row: ScheduledRow, run: ScheduledRun) {
        guard !isDemo else { return }
        Task {
            do {
                logs[run.id] = try await cli {
                    try $0.scheduledLog(row.task.id, run: run.id, workspace: row.workspace.name)
                }
            } catch {
                logs[run.id] = error.localizedDescription
            }
        }
    }

    private func perform(_ row: ScheduledRow, _ body: @escaping @Sendable (DevmachineCLI) throws -> Void) {
        busy.insert(row.id)
        Task {
            defer { busy.remove(row.id) }
            do {
                try await cli(body)
                refresh()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Reads a task's runs every two seconds until `runID` is listed and no
    /// run is still going, for at most ten minutes, so Run now shows the end
    /// without a refresh. A Run now that lands on a running one is skipped at
    /// once, and the run it met is the one to wait for.
    private func poll(_ row: ScheduledRow, until runID: String) {
        guard polling.insert(row.id).inserted else { return }
        Task {
            defer { polling.remove(row.id) }
            let deadline = Date().addingTimeInterval(600)
            try? await Task.sleep(for: .seconds(1))
            while Date() < deadline {
                guard let found = try? await cli({ try $0.scheduledRuns(row.task.id, workspace: row.workspace.name) })
                else { return }
                runs[row.id] = found
                let listed = found.contains { $0.id == runID }
                if listed && !found.contains(where: { $0.status == .running }) { break }
                try? await Task.sleep(for: .seconds(2))
            }
            refresh()
        }
    }

    #if DEBUG
    /// Demo walks only: what the page shows, with no CLI behind it.
    func seedDemo(
        workspaces: [ScheduledWorkspace], harnesses: [ScheduledHarness],
        runs: [String: [ScheduledRun]], logs: [String: String]
    ) {
        self.workspaces = workspaces
        self.harnesses = harnesses
        self.runs = runs
        self.logs = logs
        hasLoaded = true
        loadError = nil
        refreshedAt = Date()
        isDemo = true
    }
    #endif

    private func cli<T: Sendable>(_ body: @escaping @Sendable (DevmachineCLI) throws -> T) async throws -> T {
        let make = makeCLI
        return try await Task.detached { try body(try make()) }.value
    }
}
