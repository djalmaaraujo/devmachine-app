import XCTest
import DevmachineCore
@testable import DevmachineApp

@MainActor
final class DemoSiteWalkTests: XCTestCase {
    override func tearDown() async throws {
        DemoData.transcriptOverride = [:]
        DemoData.walkLocalSessions = []
        DemoContextOverride.shared.value = nil
        try await super.tearDown()
    }

    func testTheSiteWalkIsSixScenesOfNumberedFramesEachInItsOwnFolder() {
        let screens = DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "site"])
        XCTAssertEqual(
            DemoSiteWalk.scenes.map(\.id), ["operator", "sessions", "cli", "context", "publish", "scheduled", "share", "home"])
        XCTAssertEqual(screens.count, DemoSiteWalk.scenes.reduce(0) { $0 + $1.frames.count })
        XCTAssertEqual(screens.first?.fileName, "operator/001.png")
        XCTAssertEqual(Set(screens.map(\.id)).count, screens.count)
        XCTAssertTrue(screens.allSatisfy { DemoSiteWalk.handles($0.id) })
        XCTAssertFalse(DemoSnapshots.screens.contains { DemoSiteWalk.handles($0.id) })
    }

    func testEverySceneLastsEightToTwentyOneSecondsWithItsPointerMoves() {
        for scene in DemoSiteWalk.scenes {
            XCTAssertTrue((8...21).contains(scene.seconds), "\(scene.id) lasts \(scene.seconds)s")
        }
    }

    func testEveryLabelStaysTwoSecondsAndEverySceneEndsOnAPause() {
        for scene in DemoSiteWalk.scenes {
            var shown: [String: Double] = [:]
            for frame in scene.frames {
                guard let text = frame.label?.text else { continue }
                shown[text, default: 0] += frame.hold + (frame.pointer?.seconds ?? 0)
            }
            for (text, seconds) in shown {
                XCTAssertGreaterThanOrEqual(seconds, 2, "\(scene.id): \(text)")
            }
            XCTAssertGreaterThanOrEqual(scene.frames.last?.hold ?? 0, 1.5, scene.id)
        }
    }

    func testTypingRunsAtAReadingPaceAndLinesComeOneByOne() {
        let typed = Double(DemoSiteWalk.typingChunk) / DemoSiteWalk.typingSeconds
        XCTAssertTrue((12...15).contains(typed))
        let played = DemoSiteWalk.play(
            [.type(prompt: "$ ", text: "devmachine sync", label: nil), .print(["a", "", "b"], label: nil)], start: [])
        XCTAssertEqual(played.map(\.transcript), [
            "$ devma", "$ devmachine", "$ devmachine sync",
            "$ devmachine sync\na", "$ devmachine sync\na\n\nb",
        ])
        XCTAssertEqual(played.map(\.hold), [0.34, 0.34, 1.0, 0.3, DemoSiteWalk.lastSeconds])
    }

    func testEverySceneOpensOnItsSubjectWithoutAClick() {
        XCTAssertEqual(DemoSiteWalk.scenes.map { $0.frames.first?.pointer }, Array(repeating: nil, count: 8))
        XCTAssertEqual(DemoSiteWalk.scenes.map { $0.frames.first?.step }, [
            .operatorChooser, .sidebar, .cli(0), .context(0), .publishedApps, .scheduledList, .shareStart, .homeStart,
        ])
    }

    func testTheConcatListHoldsEachFrameAndNamesTheLastOneAgain() {
        XCTAssertEqual(DemoSiteWalk.ffconcat([1.5, 0.033, 3]), """
            ffconcat version 1.0
            file '001.png'
            duration 1.500
            file '002.png'
            duration 0.033
            file '003.png'
            duration 3.000
            file '003.png'

            """)
    }

    func testAClickAddsAMoveAndARingAndAHoverOnlyTheMove() {
        let spot = DemoSiteWalk.Spot(target: "footer:close-sidebar")
        func seconds(_ pointer: DemoSiteWalk.Pointer?) -> Double {
            DemoSiteWalk.Scene(id: "x", frames: [.init(step: .homeStart, hold: 1, pointer: pointer)]).seconds
        }
        XCTAssertEqual(seconds(.click(spot)) - seconds(nil), DemoPointer.clickSeconds, accuracy: 0.001)
        XCTAssertEqual(seconds(.hover(spot)) - seconds(nil), DemoPointer.moveSeconds, accuracy: 0.001)
        XCTAssertEqual(seconds(.follow(spot)), seconds(nil), accuracy: 0.001)
        XCTAssertEqual(DemoPointer.moveSeconds, 0.5, accuracy: 0.01)
        XCTAssertEqual(Double(DemoPointer.rings.count) * DemoPointer.clickFrameSeconds, 0.25, accuracy: 0.01)
    }

    func testThePointerEasesFromWhereItWasToTheTarget() {
        let path = DemoPointer.path(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 50))
        XCTAssertEqual(path.count, DemoPointer.moveFrames)
        XCTAssertEqual(path.last, CGPoint(x: 100, y: 50))
        let steps = zip(path, path.dropFirst()).map { $1.x - $0.x }
        XCTAssertLessThan(steps.first ?? 0, steps[steps.count / 2])
        XCTAssertLessThan(steps.last ?? 0, steps[steps.count / 2])
    }

    func testTheClickRingShrinksAndFades() {
        let rings = DemoPointer.rings
        XCTAssertEqual(rings.map(\.radius), rings.map(\.radius).sorted(by: >))
        XCTAssertEqual(rings.map(\.opacity), rings.map(\.opacity).sorted(by: >))
    }

    func testEveryPointerNamesAControlTheAppMarks() {
        let targets = Set(DemoSiteWalk.scenes.flatMap(\.frames).compactMap(\.pointer?.spot.target))
        XCTAssertEqual(targets, [
            "grid:acme-devmachine", "operator:Claude Code", "grid-right:claude — payments refactor",
            "grid-size:claude — payments refactor", "context:todo", "context:pull-requests",
            "link:\(DemoSiteWalk.sentryURL)",
            "session:acme-devmachine/claude — payments refactor", "sheet:share", "sheet:done", "tab:Chat",
            "site:shop.acme.example.com", "sheet:share-name", "sheet:share-for", "sheet:share-mode",
            "sheet:share-link", "sheet:share-password",
            "widget:\(DemoSiteWalk.codexUsage)", "widget:\(DemoSiteWalk.claudeUsage)", "home:add",
            "sheet:gallery:\(DemoSiteWalk.summaryType)",
            "scheduled:\(DemoScheduled.briefingID)", "scheduled:run:\(DemoScheduled.briefingRun)", "scheduled:new",
        ])
    }

    func testLabelsAreSparseAndPlain() {
        for scene in DemoSiteWalk.scenes {
            let labels = scene.frames.compactMap(\.label?.text)
            XCTAssertLessThanOrEqual(Set(labels).count, 4, scene.id)
            XCTAssertTrue(labels.allSatisfy { $0.count <= 45 }, scene.id)
        }
    }

    func testTheGridSceneOpensTheGridWithinASecondAndAHalf() throws {
        let scene = try XCTUnwrap(DemoSiteWalk.scenes.first { $0.id == "sessions" })
        let before = scene.frames.prefix { $0.step != .sessionGrid }
        let opened = before.reduce(0) { $0 + $1.hold } + DemoPointer.clickSeconds
        XCTAssertLessThanOrEqual(opened, 1.5)
        XCTAssertEqual(scene.frames.map(\.step).suffix(4), [.gridMove, .gridHalf, .gridFull, .gridRestore])
    }

    func testTheOperatorSceneStartsOnTheAgentPicker() throws {
        let scene = try XCTUnwrap(DemoSiteWalk.scenes.first)
        XCTAssertEqual(scene.frames.prefix(3).map(\.step), [.operatorChooser, .operatorChooser, .operatorPick])
    }

    func testUmbrellaKeepsTwoSessionsInTheSidebar() {
        XCTAssertEqual(DemoSiteWalk.sessions(busy: false, attention: false)["umbrella-devmachine"]?.count, 2)
        XCTAssertEqual(DemoSiteWalk.sessions(busy: false, attention: false)["acme-devmachine"]?.count, 4)
    }

    func testTheSessionsSceneMarksOneRowBusyAndAnotherWaiting() {
        let sessions = DemoSiteWalk.sessions(busy: true, attention: true)["acme-devmachine"] ?? []
        XCTAssertEqual(sessions.filter { $0.indicators?.busy == true }.map(\.name), ["claude — payments refactor"])
        XCTAssertEqual(sessions.filter { $0.indicators?.attention == true }.map(\.name), ["codex — landing page"])
        XCTAssertTrue(sessions.allSatisfy { $0.indicators?.branch != nil && $0.indicators?.ageSeconds != nil })
        let calm = DemoSiteWalk.sessions(busy: false, attention: false).values.joined()
        XCTAssertFalse(calm.contains { $0.indicators?.busy == true || $0.indicators?.attention == true })
    }

    func testTheCLISceneIsTypedIntoAPlainTerminalStepByStep() {
        let frames = DemoSiteWalk.cliPlayed.map(\.transcript)
        XCTAssertEqual(frames.count, DemoSiteWalk.scenes[2].frames.count)
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            XCTAssertTrue(later.hasPrefix(earlier))
        }
        let last = frames.last ?? ""
        XCTAssertTrue(last.contains("added main to /Users/alice/.config/devmachine/config.yml"))
        XCTAssertTrue(last.contains("added claude-code to workspace acme"))
        XCTAssertTrue(last.contains("main: ok=86 changed=12 failed=0"))
        XCTAssertNotEqual(DemoSiteWalk.terminalKind, DemoSiteWalk.operatorKind)
    }

    func testTheOperatorSceneAnswersTwoRequestsWithTheCLIsOwnWords() {
        let last = DemoSiteWalk.operatorPlayed.last?.transcript ?? ""
        for request in DemoSiteWalk.requests {
            XCTAssertTrue(last.contains(request), request)
        }
        XCTAssertTrue(last.contains("alice is in the configuration, on main, with the packages claude-code."))
        XCTAssertTrue(last.contains("added docker to machine main"))
        XCTAssertEqual(DemoSiteWalk.requests.count, 2)
        XCTAssertTrue(last.contains("memory  3.6G used of 3.8G, 210.0M available"))
        XCTAssertEqual(DemoSiteWalk.operatorPlayed.last?.label, DemoSiteWalk.answerLabel)
    }

    func testAWalkTranscriptReplacesTheSessionsOwnOnlyWhileSet() {
        let kind = DemoSiteWalk.operatorKind
        DemoData.transcriptOverride = [kind: "$ devmachine sync"]
        XCTAssertTrue(DemoData.terminalTranscript(for: kind).hasSuffix("$ devmachine sync"))
        DemoData.transcriptOverride = [:]
        XCTAssertFalse(DemoData.terminalTranscript(for: kind).hasSuffix("$ devmachine sync"))
    }

    func testTheContextSceneTicksATaskTurnsThePullRequestGreenAndCollectsALink() throws {
        let states = DemoSiteWalk.contextStates
        let done = states.map { $0.plan?.done ?? 0 }
        XCTAssertEqual(done, done.sorted())
        XCTAssertLessThan(done.first ?? 0, done.last ?? 0)
        XCTAssertEqual(states.first?.prs.first { $0.number == 415 }?.ci, "pending")
        XCTAssertEqual(states.last?.prs.first { $0.number == 415 }?.ci, "success")
        XCTAssertEqual(DemoSiteWalk.contextTranscripts.count, states.count)
        let sentry = states.map { $0.links.contains { $0.url == DemoSiteWalk.sentryURL } }
        XCTAssertEqual(sentry, [false, false, false, false, true])
        XCTAssertTrue(DemoSiteWalk.contextTranscripts[3].contains(DemoSiteWalk.sentryURL))
        XCTAssertEqual(states.last?.links.first { $0.url == DemoSiteWalk.sentryURL }?.kind, "sentry")
        XCTAssertEqual(states.last?.links.map(\.label).contains("PAY-212"), true)
    }

    func testTheLinksStepLastsLongestAndTheCameraZoomsInAndBackOut() throws {
        let scene = try XCTUnwrap(DemoSiteWalk.scenes.first { $0.id == "context" })
        var seconds: [String: Double] = [:]
        for frame in scene.frames {
            guard let zoom = frame.zoom else { continue }
            seconds[zoom, default: 0] += frame.hold + (frame.pointer?.seconds ?? 0)
        }
        let links = try XCTUnwrap(seconds["context:links"])
        XCTAssertTrue(seconds.values.allSatisfy { $0 <= links })
        XCTAssertNil(scene.frames.first?.zoom)
        XCTAssertNil(scene.frames.last?.zoom)
        XCTAssertEqual(DemoCamera.seconds, 0.8, accuracy: 0.01)
        XCTAssertTrue((1.8...2).contains(DemoCamera.zoom))
    }

    func testTheCameraKeepsTheWindowShapeInsideTheWindow() {
        let rect = DemoCamera.rect(around: CGRect(x: 1500, y: 900, width: 80, height: 40))
        XCTAssertEqual(rect.width / rect.height, DemoCamera.window.width / DemoCamera.window.height, accuracy: 0.001)
        XCTAssertTrue(DemoCamera.window.contains(rect))
        XCTAssertEqual(DemoCamera.path(from: nil, to: rect).last, rect)
        XCTAssertEqual(DemoCamera.path(from: rect, to: nil).last, DemoCamera.window)
    }

    func testTheDemoContextAnswersWithTheWalksStateWhileOneIsSet() throws {
        let target = CommandTarget.remote(alias: "globex-devmachine", session: "claude")
        let walkState = try XCTUnwrap(DemoSiteWalk.contextStates.last)
        DemoContextOverride.shared.value = walkState
        XCTAssertEqual(try DemoContextSource().context(for: target, settings: .empty), walkState)
        DemoContextOverride.shared.value = nil
        XCTAssertEqual(try DemoContextSource().context(for: target, settings: .empty), DemoData.contextState)
    }

    func testEachShareDialogStaysOpenThreeSeconds() {
        let frames = DemoSiteWalk.scenes.first { $0.id == "share" }?.frames ?? []
        for step in [DemoSiteWalk.Step.shareSheet, .shareLink] {
            let seconds = frames.filter { $0.step == step }.reduce(0) { $0 + $1.hold }
            XCTAssertGreaterThanOrEqual(seconds, 3, "\(step)")
        }
    }

    func testSheetsAndThePopoverAreDrawnOverTheWindow() {
        let model = AppModel()
        XCTAssertNotNil(DemoSiteWalk.sheet(for: .shareSheet, model: model))
        XCTAssertNotNil(DemoSiteWalk.sheet(for: .shareLink, model: model))
        XCTAssertNotNil(DemoSiteWalk.sheet(for: .scheduledNew, model: model))
        XCTAssertEqual(DemoSiteWalk.sheet(for: .homeGallery, model: model)?.below, "home:add")
        XCTAssertNil(DemoSiteWalk.sheet(for: .shared, model: model))
    }

    func testTheScheduledDemoReadsThroughTheCLIsJSON() {
        let store = ScheduledStore(makeCLI: { throw DevmachineCLIError.commandFailed("no CLI in a demo") })
        DemoScheduled.seed(store)
        XCTAssertEqual(store.rows.count, 5)
        XCTAssertNotNil(store.row(DemoScheduled.briefingID))
        XCTAssertEqual(store.runs[DemoScheduled.briefingID]?.first?.id, DemoScheduled.briefingRun)
        XCTAssertNil(DemoScheduled.weeklyDraft.problem)
    }

    func testClickTargetsAreRecordedOnlyWhileAWalkCaptures() {
        XCTAssertFalse(DemoClickTargets.isRecording)
    }
}
