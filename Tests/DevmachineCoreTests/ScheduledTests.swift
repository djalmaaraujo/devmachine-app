import XCTest
@testable import DevmachineCore

final class ScheduledTests: XCTestCase {
    private let listJSON = """
    {
      "workspaces": [
        {
          "name": "alice",
          "machine": "main",
          "installed": true,
          "tasks": [
            {
              "version": 1,
              "id": "t_7f3a9c",
              "name": "Daily briefing",
              "paused": false,
              "done": false,
              "folder": "~/dev/app",
              "timeout": "30m",
              "schedule": {"every": "weekdays", "at": "09:00", "timezone": "America/Sao_Paulo"},
              "action": {"kind": "prompt", "harness": "claude", "prompt": "Summarize", "permission_mode": "acceptEdits"},
              "created_at": "2026-10-15T12:00:00Z",
              "updated_at": "2026-10-15T12:00:00.123456789-03:00",
              "next_run_at": "2026-10-16T12:00:00Z",
              "last_run": {
                "id": "20261015T120000Z-ab12",
                "task_id": "t_7f3a9c",
                "status": "failed",
                "trigger": "schedule",
                "started_at": "2026-10-15T22:47:00.090663883-03:00",
                "ended_at": "2026-10-15T22:48:10.5-03:00",
                "duration_ms": 70000,
                "exit_code": 3
              }
            }
          ]
        },
        {"name": "bob", "machine": "main", "installed": false, "tasks": []},
        {"name": "carol", "machine": "edge", "installed": true, "tasks": [],
         "error": {"kind": "unreachable", "message": "no address answered"}}
      ]
    }
    """

    func testDecodesTheListTheCLIPrints() throws {
        let workspaces = try ScheduledJSON.decodeList(Data(listJSON.utf8))
        XCTAssertEqual(workspaces.map(\.name), ["alice", "bob", "carol"])
        let task = try XCTUnwrap(workspaces.first?.tasks.first)
        XCTAssertEqual(task.id, "t_7f3a9c")
        XCTAssertEqual(task.action.permissionMode, "acceptEdits")
        XCTAssertEqual(task.schedule.timezone, "America/Sao_Paulo")
        XCTAssertNotNil(task.nextRunAt)
        XCTAssertEqual(task.lastRun?.exitCode, 3)
        XCTAssertEqual(task.lastRun?.status, .failed)
        XCTAssertEqual(task.lastRun?.startedAt.timeIntervalSince1970 ?? 0, 1_792_115_220.09, accuracy: 0.01)
        XCTAssertFalse(workspaces[1].installed)
        XCTAssertEqual(workspaces[2].error?.kind, "unreachable")
    }

    func testAnUnknownRunStatusStillDecodes() throws {
        let json = #"{"id":"20261015T120000Z-ab12","task_id":"t_000001","status":"exploded","trigger":"manual","started_at":"2026-10-15T12:00:00Z","duration_ms":0}"#
        let run = try ScheduledJSON.decoder().decode(ScheduledRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.status, .other("exploded"))
        XCTAssertNil(run.endedAt)
    }

    func testDescribe() {
        XCTAssertEqual(ScheduledSchedule(every: "weekdays", at: "09:00", timezone: "UTC").describe, "Weekdays at 09:00")
        XCTAssertEqual(ScheduledSchedule(every: "hourly", minute: 5, timezone: "UTC").describe, "Every hour at :05")
        XCTAssertEqual(ScheduledSchedule(every: "weekly", at: "18:00", weekday: "fri", timezone: "UTC").describe, "Every Friday at 18:00")
        XCTAssertEqual(ScheduledSchedule(every: "monthly", at: "09:00", day: 31, timezone: "UTC").describe, "Monthly on day 31 at 09:00")
        XCTAssertEqual(ScheduledSchedule(every: "once", at: "09:00", date: "2026-10-16", timezone: "UTC").describe, "Once on 2026-10-16 at 09:00")
        XCTAssertEqual(ScheduledSchedule(every: "daily", at: "07:30", timezone: "UTC").describe, "Daily at 07:30")
    }

    private func promptDraft() -> ScheduledDraft {
        var d = ScheduledDraft(workspace: "alice", timezone: "America/Sao_Paulo")
        d.name = "Daily briefing"
        d.folder = "~/dev/app"
        d.kind = .prompt
        d.harness = "claude"
        d.prompt = "it's \"quoted\"\nand $(not run)"
        d.model = "sonnet"
        d.permissionMode = "acceptEdits"
        d.every = "weekdays"
        d.at = "09:00"
        return d
    }

    func testAddArguments() {
        XCTAssertEqual(promptDraft().arguments(editing: nil, allowDangerous: false), [
            "--format", "json", "scheduled", "add", "--workspace", "alice",
            "--name", "Daily briefing", "--folder", "~/dev/app",
            "--harness", "claude", "--prompt", "it's \"quoted\"\nand $(not run)",
            "--model", "sonnet", "--permission-mode", "acceptEdits",
            "--every", "weekdays", "--at", "09:00", "--timezone", "America/Sao_Paulo",
            "--timeout", "30m", "--yes",
        ])
    }

    func testEditArgumentsClearAnEmptyModelAndCarryEachKindsField() {
        var d = promptDraft()
        d.model = ""
        d.every = "monthly"
        d.day = 31
        let args = d.arguments(editing: "t_7f3a9c", allowDangerous: true)
        XCTAssertEqual(Array(args.prefix(6)), ["--format", "json", "scheduled", "edit", "t_7f3a9c", "--workspace"])
        XCTAssertTrue(args.contains("--allow-dangerous"))
        XCTAssertFalse(args.contains("--yes"))
        let model = args.firstIndex(of: "--model")!
        XCTAssertEqual(args[model + 1], "")
        let day = args.firstIndex(of: "--day")!
        XCTAssertEqual(args[day + 1], "31")
    }

    func testCommandArgumentsLeaveOutThePromptFields() {
        var d = promptDraft()
        d.kind = .command
        d.command = "make report"
        d.every = "hourly"
        d.minute = 15
        let args = d.arguments(editing: nil, allowDangerous: false)
        XCTAssertTrue(args.contains("--command"))
        XCTAssertFalse(args.contains("--harness"))
        XCTAssertFalse(args.contains("--at"))
        let minute = args.firstIndex(of: "--minute")!
        XCTAssertEqual(args[minute + 1], "15")
    }

    func testProblems() {
        var d = promptDraft()
        XCTAssertNil(d.problem)
        d.name = " "
        XCTAssertEqual(d.problem, "Give the task a name.")
        d = promptDraft()
        d.prompt = ""
        XCTAssertEqual(d.problem, "Write the prompt.")
        d = promptDraft()
        d.kind = .command
        d.command = ""
        XCTAssertEqual(d.problem, "Write the command.")
        d = promptDraft()
        d.every = "once"
        d.date = "16/10/2026"
        XCTAssertEqual(d.problem, "Pick a date, such as 2026-10-16.")
        d = promptDraft()
        d.at = "9am"
        XCTAssertEqual(d.problem, "Pick a time, such as 09:00.")
    }

    func testDraftFromATaskRoundTrips() throws {
        let task = try XCTUnwrap(try ScheduledJSON.decodeList(Data(listJSON.utf8)).first?.tasks.first)
        let d = ScheduledDraft(task: task, workspace: "alice")
        XCTAssertEqual(d.name, "Daily briefing")
        XCTAssertEqual(d.kind, .prompt)
        XCTAssertEqual(d.permissionMode, "acceptEdits")
        XCTAssertEqual(d.every, "weekdays")
        XCTAssertEqual(d.timezone, "America/Sao_Paulo")
        XCTAssertEqual(d.timeout, "30m")
    }
}
