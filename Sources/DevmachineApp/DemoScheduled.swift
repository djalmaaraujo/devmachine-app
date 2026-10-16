#if DEBUG
import Foundation
import DevmachineCore

/// Debug builds only. The Scheduled page as the website shows it: a few
/// tasks people actually schedule, with their runs and one briefing's output,
/// built from the JSON the CLI prints so the demo reads through the same code.
@MainActor
enum DemoScheduled {
    static let briefingID = "acme/t_b41e0c"
    static let briefingRun = "20261001T120000Z-9a1f"

    static func seed(_ store: ScheduledStore, now: Date = Date()) {
        store.seedDemo(
            workspaces: (try? ScheduledJSON.decodeList(Data(listJSON(now: now).utf8))) ?? [],
            harnesses: harnesses,
            runs: [briefingID: (try? ScheduledJSON.decodeRuns(Data(runsJSON(now: now).utf8))) ?? []],
            logs: [briefingRun: briefingOutput])
        store.selectedID = nil
        store.openRunID = nil
    }

    static let harnesses: [ScheduledHarness] = (try? ScheduledJSON.decodeHarnesses(Data("""
    {"harnesses":[
      {"name":"claude","package":"claude-code","permission_modes":["manual","dontAsk","plan","acceptEdits","auto","bypassPermissions"],"dangerous":["bypassPermissions"],"models":["fable","opus","sonnet","haiku"]},
      {"name":"codex","package":"codex","permission_modes":["read-only","workspace-write","danger-full-access","approve-for-me","dangerously-bypass-approvals-and-sandbox"],"dangerous":["danger-full-access","dangerously-bypass-approvals-and-sandbox"],"models":[]}
    ]}
    """.utf8))) ?? []

    /// What the New task sheet shows filled in.
    static var weeklyDraft: ScheduledDraft {
        var d = ScheduledDraft(workspace: "acme", timezone: "America/New_York")
        d.name = "Friday release notes"
        d.folder = "~/acme-web"
        d.kind = .prompt
        d.harness = "claude"
        d.model = "sonnet"
        d.permissionMode = "auto"
        d.prompt = "Draft release notes from this week's merged pull requests, grouped by area, " +
            "and open them as a pull request against main."
        d.every = "weekly"
        d.weekday = "fri"
        d.at = "16:00"
        return d
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func task(
        id: String, name: String, folder: String, schedule: String, action: String,
        next: Date?, last: (status: String, at: Date, seconds: Int)?, paused: Bool = false
    ) -> String {
        let lastRun = last.map {
            """
            {"id":"\(String(id.prefix(8)))-run","task_id":"\(id)","status":"\($0.status)","trigger":"schedule",\
            "started_at":"\(iso($0.at))","ended_at":"\(iso($0.at.addingTimeInterval(Double($0.seconds))))",\
            "duration_ms":\($0.seconds * 1000),"exit_code":0}
            """
        } ?? "null"
        return """
        {"version":1,"id":"\(id)","name":"\(name)","paused":\(paused),"done":false,"folder":"\(folder)",\
        "timeout":"30m","schedule":\(schedule),"action":\(action),"created_at":"\(iso(Date()))",\
        "updated_at":"\(iso(Date()))","next_run_at":\(next.map { "\"\(iso($0))\"" } ?? "null"),"last_run":\(lastRun)}
        """
    }

    static func listJSON(now: Date) -> String {
        let hour = 3_600.0
        let day = 86_400.0
        let briefing = task(
            id: "t_b41e0c", name: "Monthly briefing", folder: "~/acme-web",
            schedule: #"{"every":"monthly","day":1,"at":"09:00","timezone":"America/New_York"}"#,
            action: #"{"kind":"prompt","harness":"claude","model":"opus","permission_mode":"auto","prompt":"Brief me on last month in acme: what shipped, the pull requests still open, Sentry's top new errors and the deploys. Keep it to one page and email it to me."}"#,
            next: Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: briefingTime(monthsAgo: 0, now: now)),
            last: ("succeeded", briefingTime(monthsAgo: 0, now: now), 94))
        let standup = task(
            id: "t_57a2d1", name: "Standup notes", folder: "~/acme-web",
            schedule: #"{"every":"weekdays","at":"08:30","timezone":"America/New_York"}"#,
            action: #"{"kind":"prompt","harness":"claude","model":"sonnet","permission_mode":"auto","prompt":"Read yesterday's commits and Linear updates and write my standup in standup.md."}"#,
            next: now.addingTimeInterval(14 * hour), last: ("succeeded", now.addingTimeInterval(-10 * hour), 41))
        let deps = task(
            id: "t_d3a5c4", name: "Dependency check", folder: "~/acme-web",
            schedule: #"{"every":"weekly","weekday":"mon","at":"07:00","timezone":"America/New_York"}"#,
            action: #"{"kind":"command","command":"npm outdated && npm audit --omit=dev"}"#,
            next: now.addingTimeInterval(3 * day), last: ("failed", now.addingTimeInterval(-4 * day), 12))
        let notes = task(
            id: "t_9f2e71", name: "Friday release notes", folder: "~/acme-web",
            schedule: #"{"every":"weekly","weekday":"fri","at":"16:00","timezone":"America/New_York"}"#,
            action: #"{"kind":"prompt","harness":"codex","permission_mode":"workspace-write","prompt":"Draft release notes from this week's merged pull requests."}"#,
            next: now.addingTimeInterval(1 * day + 6 * hour), last: ("succeeded", now.addingTimeInterval(-6 * day), 63))
        let backup = task(
            id: "t_0b4c6a", name: "Nightly database backup", folder: "~/beta-api",
            schedule: #"{"every":"daily","at":"02:00","timezone":"America/New_York"}"#,
            action: #"{"kind":"command","command":"./scripts/backup.sh --to s3://beta-backups"}"#,
            next: now.addingTimeInterval(9 * hour), last: ("succeeded", now.addingTimeInterval(-15 * hour), 182))
        return """
        {"workspaces":[
          {"name":"acme","machine":"main","installed":true,"tasks":[\(briefing),\(standup),\(deps),\(notes)]},
          {"name":"beta","machine":"main","installed":true,"tasks":[\(backup)]}
        ]}
        """
    }

    /// The 1st of a month at 09:00 in New York, `monthsAgo` before the
    /// latest one that has passed: when the briefing runs.
    static func briefingTime(monthsAgo: Int, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var parts = calendar.dateComponents([.year, .month], from: now)
        parts.day = 1
        parts.hour = 9
        var first = calendar.date(from: parts) ?? now
        if first > now { first = calendar.date(byAdding: .month, value: -1, to: first) ?? first }
        return calendar.date(byAdding: .month, value: -monthsAgo, to: first) ?? first
    }

    static func runsJSON(now: Date) -> String {
        func run(_ id: String, _ monthsAgo: Int, _ status: String, _ seconds: Int, trigger: String = "schedule") -> String {
            var at = briefingTime(monthsAgo: monthsAgo, now: now)
            if trigger == "manual" { at = at.addingTimeInterval(-15 * 3_600) }
            return """
            {"id":"\(id)","task_id":"t_b41e0c","status":"\(status)","trigger":"\(trigger)","started_at":"\(iso(at))",\
            "ended_at":"\(iso(at.addingTimeInterval(Double(seconds))))","duration_ms":\(seconds * 1000),"exit_code":0}
            """
        }
        return """
        {"runs":[\(run(briefingRun, 0, "succeeded", 94)),\(run("20260930T181200Z-2c7d", 0, "succeeded", 88, trigger: "manual")),\
        \(run("20260901T130000Z-5e0b", 1, "succeeded", 102)),\(run("20260801T130000Z-71aa", 2, "succeeded", 97))]}
        """
    }

    static let briefingOutput = """
    # acme — last month
    Shipped: checkout retries on a declined card (#412), the lazy hero (#398).
    Open: #421 refund webhooks double-post, waiting on review for 6 days.
    Sentry: a new TypeError in cart/summary.tsx, 214 events since the 26th.
    Deploys: 23, none rolled back.
    Sent to alice@example.com.
    """
}
#endif
