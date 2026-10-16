import Foundation

/// The New/Edit task form, and the `scheduled add`/`edit` call it becomes.
public struct ScheduledDraft: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case prompt, command }

    public static let everyChoices: [(value: String, title: String)] = [
        ("once", "Once"), ("hourly", "Hourly"), ("daily", "Daily"),
        ("weekdays", "Weekdays"), ("weekly", "Weekly"), ("monthly", "Monthly"),
    ]
    public static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    public var workspace: String
    public var name = ""
    public var folder = "~"
    public var kind: Kind = .prompt
    public var harness = "claude"
    public var prompt = ""
    public var command = ""
    public var model = ""
    public var permissionMode = "acceptEdits"
    public var every = "daily"
    public var at = "09:00"
    public var minute = 0
    public var weekday = "mon"
    public var day = 1
    public var date: String
    public var timezone: String
    public var timeout = "30m"

    public init(workspace: String, timezone: String = TimeZone.current.identifier, today: Date = Date()) {
        self.workspace = workspace
        self.timezone = timezone
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: timezone)
        date = f.string(from: today)
    }

    public init(task: ScheduledTask, workspace: String) {
        self.init(workspace: workspace, timezone: task.schedule.timezone)
        name = task.name
        folder = task.folder
        timeout = task.timeout ?? "30m"
        let s = task.schedule
        every = s.every
        at = s.at ?? at
        minute = s.minute ?? 0
        weekday = s.weekday ?? weekday
        day = s.day ?? day
        date = s.date ?? date
        if task.action.isPrompt {
            kind = .prompt
            harness = task.action.harness ?? harness
            prompt = task.action.prompt ?? ""
            model = task.action.model ?? ""
            permissionMode = task.action.permissionMode ?? ""
        } else {
            kind = .command
            command = task.action.command ?? ""
        }
    }

    static func isClock(_ text: String) -> Bool {
        text.wholeMatch(of: /([01]\d|2[0-3]):[0-5]\d/) != nil
    }

    static func isDate(_ text: String) -> Bool {
        text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }

    /// What stops the form from saving, in the words the sheet shows.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the task a name." }
        if folder.trimmingCharacters(in: .whitespaces).isEmpty { return "Pick the folder it runs in." }
        switch kind {
        case .prompt where prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return "Write the prompt."
        case .command where command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return "Write the command."
        default: break
        }
        if every != "hourly", !Self.isClock(at) { return "Pick a time, such as 09:00." }
        if every == "once", !Self.isDate(date) { return "Pick a date, such as 2026-10-16." }
        return nil
    }

    /// The CLI call that saves the form: `add` for a new task, `edit` for
    /// `editing`. Every field goes, so an edit says the whole task. `--yes`
    /// on add sets the package up when the workspace has none; the app has
    /// already asked.
    public func arguments(editing id: String?, allowDangerous: Bool) -> [String] {
        var args = ["--format", "json", "scheduled"]
        args += id.map { ["edit", $0] } ?? ["add"]
        args += ["--workspace", workspace, "--name", name, "--folder", folder]
        switch kind {
        case .prompt:
            args += ["--harness", harness, "--prompt", prompt, "--model", model, "--permission-mode", permissionMode]
        case .command:
            args += ["--command", command]
        }
        args += ["--every", every]
        switch every {
        case "hourly": args += ["--minute", String(minute)]
        case "weekly": args += ["--weekday", weekday, "--at", at]
        case "monthly": args += ["--day", String(day), "--at", at]
        case "once": args += ["--date", date, "--at", at]
        default: args += ["--at", at]
        }
        args += ["--timezone", timezone, "--timeout", timeout]
        if allowDangerous { args.append("--allow-dangerous") }
        if id == nil { args.append("--yes") }
        return args
    }
}
