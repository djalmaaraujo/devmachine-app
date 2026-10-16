import Foundation
import DevmachineCore

/// The `devmachine` commands one job runs against one machine, in order.
struct MachineJobPlan: Equatable, Sendable {
    let machine: String
    let title: String
    let steps: [[String]]
}

enum MachineJobPhase: Equatable {
    case pending
    case queued
    case running(step: Int)
    case succeeded(SyncSummary?)
    case failed(cause: String)
    case cancelled
}

extension MachineJobPhase {
    /// Started: running, or waiting for the machine's job before it. A
    /// pending job still waits for the person to start it.
    var isUnderway: Bool {
        switch self {
        case .queued, .running: return true
        case .pending, .succeeded, .failed, .cancelled: return false
        }
    }
}

enum MachineJobOutcome: Equatable {
    case succeeded
    case failed
    case cancelled
}

struct MachineJob: Identifiable, Equatable {
    let id: UUID
    var plan: MachineJobPlan
    var phase: MachineJobPhase
    var log: JobLog
    var request: SyncRequest?
    var expanded: Bool
    var currentCommand: String?
}

/// Every background `devmachine` job the app runs against a machine. A sync
/// asked for while one waits joins it, and a machine runs one job at a time:
/// the next waits its turn, while other machines go on in parallel.
@MainActor
final class MachineJobCenter: ObservableObject {
    @Published private(set) var jobs: [MachineJob] = []
    var cliVersion: @MainActor () -> SemanticVersion?

    private let runner: any MachineJobRunning
    private let successSeconds: Double
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var callbacks: [UUID: [(MachineJobOutcome) -> Void]] = [:]

    init(
        runner: any MachineJobRunning = ProcessJobRunner(),
        cliVersion: @escaping @MainActor () -> SemanticVersion? = { nil },
        successSeconds: Double = 6
    ) {
        self.runner = runner
        self.cliVersion = cliVersion
        self.successSeconds = successSeconds
    }

    func job(_ id: UUID) -> MachineJob? {
        jobs.first { $0.id == id }
    }

    /// `onFinish` hears every run that ends, so a retried failure reports
    /// again; it is dropped once the job succeeds, is cancelled or dismissed.
    @discardableResult
    func requestSync(_ request: SyncRequest, onFinish: ((MachineJobOutcome) -> Void)? = nil) -> UUID {
        if let index = jobs.firstIndex(where: { $0.phase == .pending && $0.plan.machine == request.machine }),
           let current = jobs[index].request {
            jobs[index].request = current.merging(request)
            addCallback(onFinish, to: jobs[index].id)
            return jobs[index].id
        }
        let job = MachineJob(
            id: UUID(), plan: MachineJobPlan(machine: request.machine, title: "Sync \(request.machine)", steps: []),
            phase: .pending, log: JobLog(), request: request, expanded: false)
        jobs.append(job)
        addCallback(onFinish, to: job.id)
        return job.id
    }

    /// `onFinish` hears every run that ends, as `requestSync` describes.
    @discardableResult
    func run(_ plan: MachineJobPlan, onFinish: ((MachineJobOutcome) -> Void)? = nil) -> UUID {
        let job = MachineJob(id: UUID(), plan: plan, phase: .pending, log: JobLog(), expanded: false)
        jobs.append(job)
        addCallback(onFinish, to: job.id)
        launch(job.id)
        return job.id
    }

    func startsFull(_ id: UUID) -> Bool {
        job(id)?.request?.startsFull(cliVersion: cliVersion()) ?? false
    }

    func start(_ id: UUID, full: Bool) {
        guard let index = index(of: id), jobs[index].phase == .pending, let request = jobs[index].request else { return }
        let plan = jobs[index].plan
        jobs[index].plan = MachineJobPlan(
            machine: plan.machine, title: plan.title, steps: [request.arguments(full: full)])
        launch(id)
    }

    func cancel(_ id: UUID) {
        guard let job = job(id) else { return }
        switch job.phase {
        case .pending, .queued:
            remove(id)
            fire(id, .cancelled)
        case .running:
            tasks[id]?.cancel()
        case .succeeded, .failed, .cancelled:
            break
        }
    }

    func retry(_ id: UUID) {
        guard let index = index(of: id), case .failed = jobs[index].phase else { return }
        jobs[index].log = JobLog()
        launch(id)
    }

    func dismiss(_ id: UUID) {
        guard let job = job(id) else { return }
        if case .running = job.phase { return }
        let machine = job.plan.machine
        remove(id)
        if case .failed = job.phase {
            callbacks[id] = nil
        } else {
            fire(id, .cancelled)
        }
        startNext(on: machine)
    }

    func toggleExpanded(_ id: UUID) {
        guard let index = index(of: id) else { return }
        jobs[index].expanded.toggle()
        if case .succeeded = jobs[index].phase, !jobs[index].expanded { removeAfterSuccess(id) }
    }

    private func index(of id: UUID) -> Int? {
        jobs.firstIndex { $0.id == id }
    }

    private func addCallback(_ callback: ((MachineJobOutcome) -> Void)?, to id: UUID) {
        guard let callback else { return }
        callbacks[id, default: []].append(callback)
    }

    private func fire(_ id: UUID, _ outcome: MachineJobOutcome) {
        let waiting = outcome == .failed ? callbacks[id] : callbacks.removeValue(forKey: id)
        waiting?.forEach { $0(outcome) }
    }

    private func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    private func isBusy(_ machine: String, besides id: UUID) -> Bool {
        jobs.contains { job in
            guard job.id != id, job.plan.machine == machine else { return false }
            switch job.phase {
            case .running, .queued: return true
            default: return false
            }
        }
    }

    private func launch(_ id: UUID) {
        guard let index = index(of: id) else { return }
        if isBusy(jobs[index].plan.machine, besides: id) {
            jobs[index].phase = .queued
        } else {
            execute(id)
        }
    }

    private func startNext(on machine: String) {
        let running = jobs.contains { job in
            guard job.plan.machine == machine, case .running = job.phase else { return false }
            return true
        }
        guard !running, let next = jobs.first(where: { $0.plan.machine == machine && $0.phase == .queued }) else {
            return
        }
        execute(next.id)
    }

    private func execute(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let plan = jobs[index].plan
        jobs[index].phase = .running(step: 0)
        jobs[index].log = JobLog()
        let buffer = JobOutputBuffer { [weak self] lines in self?.append(lines, to: id) }
        let runner = self.runner
        tasks[id] = Task { [weak self] in
            var outcome = MachineJobOutcome.succeeded
            var fallback = ""
            for (step, arguments) in plan.steps.enumerated() {
                if Task.isCancelled {
                    outcome = .cancelled
                    break
                }
                let command = "devmachine " + arguments.joined(separator: " ")
                self?.beginStep(step, command: command, of: id)
                buffer.receive("$ " + command)
                do {
                    let status = try await runner.run(arguments: arguments, output: { buffer.receive($0) })
                    if status != 0 {
                        outcome = Task.isCancelled ? .cancelled : .failed
                        fallback = "devmachine exited with status \(status)."
                        break
                    }
                } catch is CancellationError {
                    outcome = .cancelled
                    break
                } catch {
                    outcome = Task.isCancelled ? .cancelled : .failed
                    fallback = error.localizedDescription
                    break
                }
            }
            buffer.flushNow()
            self?.finish(id, outcome: outcome, fallback: fallback)
        }
    }

    private func beginStep(_ step: Int, command: String, of id: UUID) {
        guard let index = index(of: id) else { return }
        jobs[index].phase = .running(step: step)
        jobs[index].currentCommand = command
    }

    private func append(_ lines: [String], to id: UUID) {
        guard let index = index(of: id) else { return }
        jobs[index].log.append(contentsOf: lines)
    }

    private func finish(_ id: UUID, outcome: MachineJobOutcome, fallback: String) {
        tasks[id] = nil
        guard let index = index(of: id) else {
            callbacks.removeValue(forKey: id)?.forEach { $0(outcome) }
            return
        }
        let machine = jobs[index].plan.machine
        switch outcome {
        case .succeeded:
            jobs[index].phase = .succeeded(SyncSummary.parse(jobs[index].log.lines))
            removeAfterSuccess(id)
        case .failed:
            let lines = jobs[index].log.lines
            jobs[index].phase = .failed(
                cause: JobFailure.cause(lines) ?? FailureCause(message: fallback)?.summary ?? fallback)
        case .cancelled:
            remove(id)
        }
        fire(id, outcome)
        startNext(on: machine)
    }

    private func removeAfterSuccess(_ id: UUID) {
        let nanoseconds = UInt64(max(successSeconds, 0) * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, let job = self.job(id), case .succeeded = job.phase, !job.expanded else { return }
            self.remove(id)
        }
    }

    #if DEBUG
    /// Demo walks only: jobs at one fixed moment, with nothing running.
    func seedDemo(_ jobs: [MachineJob]) {
        self.jobs = jobs
    }
    #endif
}
