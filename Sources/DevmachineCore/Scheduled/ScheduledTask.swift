import Foundation

/// When a task runs, as `devmachine scheduled` stores it: in the person's
/// timezone, with only the fields its `every` needs.
public struct ScheduledSchedule: Codable, Equatable, Sendable {
    public var every: String
    public var at: String?
    public var minute: Int?
    public var weekday: String?
    public var day: Int?
    public var date: String?
    public var timezone: String

    public init(
        every: String, at: String? = nil, minute: Int? = nil, weekday: String? = nil,
        day: Int? = nil, date: String? = nil, timezone: String
    ) {
        self.every = every
        self.at = at
        self.minute = minute
        self.weekday = weekday
        self.day = day
        self.date = date
        self.timezone = timezone
    }

    public static let weekdayNames: [String: String] = [
        "mon": "Monday", "tue": "Tuesday", "wed": "Wednesday", "thu": "Thursday",
        "fri": "Friday", "sat": "Saturday", "sun": "Sunday",
    ]

    /// The schedule in words, the same as the CLI's table says it.
    public var describe: String {
        let time = at ?? ""
        switch every {
        case "hourly": return minute.map { String(format: "Every hour at :%02d", $0) } ?? "Every hour"
        case "daily": return "Daily at \(time)"
        case "weekdays": return "Weekdays at \(time)"
        case "weekly": return "Every \(Self.weekdayNames[weekday ?? ""] ?? weekday ?? "week") at \(time)"
        case "monthly": return "Monthly on day \(day ?? 1) at \(time)"
        case "once": return "Once on \(date ?? "") at \(time)"
        default: return every
        }
    }
}

/// What a task runs: a shell command, or a prompt for a coding agent.
public struct ScheduledAction: Codable, Equatable, Sendable {
    public var kind: String
    public var command: String?
    public var harness: String?
    public var prompt: String?
    public var model: String?
    public var permissionMode: String?

    enum CodingKeys: String, CodingKey {
        case kind, command, harness, prompt, model
        case permissionMode = "permission_mode"
    }

    public var isPrompt: Bool { kind == "prompt" }
}

/// How a run ended, or `running` while it goes. A status a newer CLI adds
/// still decodes, as `other`.
public enum ScheduledRunStatus: Equatable, Sendable, Codable {
    case running, succeeded, failed, timeout, error, missed, skipped
    case other(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "running": self = .running
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "timeout": self = .timeout
        case "error": self = .error
        case "missed": self = .missed
        case "skipped": self = .skipped
        default: self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }

    public var text: String {
        switch self {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .timeout: return "timeout"
        case .error: return "error"
        case .missed: return "missed"
        case .skipped: return "skipped"
        case .other(let raw): return raw
        }
    }
}

public struct ScheduledRun: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let status: ScheduledRunStatus
    public let trigger: String
    public let startedAt: Date
    public let endedAt: Date?
    public let durationMS: Int
    public let exitCode: Int?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case id, status, trigger, message
        case taskID = "task_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMS = "duration_ms"
        case exitCode = "exit_code"
    }
}

public struct ScheduledTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let paused: Bool
    public let done: Bool
    public let folder: String
    public let timeout: String?
    public let schedule: ScheduledSchedule
    public let action: ScheduledAction
    public let nextRunAt: Date?
    public let lastRun: ScheduledRun?

    enum CodingKeys: String, CodingKey {
        case id, name, paused, done, folder, timeout, schedule, action
        case nextRunAt = "next_run_at"
        case lastRun = "last_run"
    }

    /// What runs it, as a short label: the agent's name, or "Command".
    public var actionLabel: String {
        guard action.isPrompt, let harness = action.harness else { return "Command" }
        return harness.prefix(1).uppercased() + harness.dropFirst()
    }
}

public struct ScheduledError: Codable, Equatable, Sendable {
    public let kind: String
    public let message: String
}

/// One workspace in `scheduled list`: its tasks, or why it could not answer.
public struct ScheduledWorkspace: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let machine: String
    public let installed: Bool
    public let tasks: [ScheduledTask]
    public let error: ScheduledError?

    public var id: String { name }
}

/// A coding agent a prompt can run in, from `scheduled harnesses`: the
/// CLI's own list, so a new agent needs no app release.
public struct ScheduledHarness: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let package: String
    public let permissionModes: [String]
    public let dangerous: [String]
    public let models: [String]

    enum CodingKeys: String, CodingKey {
        case name, package, dangerous, models
        case permissionModes = "permission_modes"
    }

    public var id: String { name }
    public func isDangerous(_ mode: String) -> Bool { dangerous.contains(mode) }
}

public enum ScheduledJSON {
    private struct List: Decodable { let workspaces: [ScheduledWorkspace] }
    private struct Harnesses: Decodable { let harnesses: [ScheduledHarness] }
    private struct Runs: Decodable { let runs: [ScheduledRun] }
    private struct Saved: Decodable { let task: ScheduledTask }
    private struct Started: Decodable { let runID: String
        enum CodingKeys: String, CodingKey { case runID = "run_id" }
    }

    /// Go writes times as RFC 3339 with up to nine digits of fractions,
    /// which Foundation's ISO 8601 reader refuses; the fraction is cut to
    /// milliseconds before reading.
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a time: \(raw)"))
            }
            return date
        }
        return d
    }

    static func parseDate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<end]
            text.replaceSubrange(dot..<end, with: "." + String((digits + "000").prefix(3)))
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    public static func decodeList(_ data: Data) throws -> [ScheduledWorkspace] {
        try decoder().decode(List.self, from: data).workspaces
    }

    public static func decodeHarnesses(_ data: Data) throws -> [ScheduledHarness] {
        try decoder().decode(Harnesses.self, from: data).harnesses
    }

    public static func decodeRuns(_ data: Data) throws -> [ScheduledRun] {
        try decoder().decode(Runs.self, from: data).runs
    }

    public static func decodeSaved(_ data: Data) throws -> ScheduledTask {
        try decoder().decode(Saved.self, from: data).task
    }

    public static func decodeRunID(_ data: Data) throws -> String {
        try decoder().decode(Started.self, from: data).runID
    }
}
