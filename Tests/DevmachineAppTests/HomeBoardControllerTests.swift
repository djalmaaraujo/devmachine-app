import XCTest
import DevmachineCore
@testable import DevmachineApp

@MainActor
final class HomeBoardControllerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeBoardControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController(
        catalog: WidgetCatalog = DemoData.widgetCatalog, store: WidgetCatalogStore? = nil
    ) -> HomeBoardController {
        let catalogStore = store ?? WidgetCatalogStore(read: { catalog })
        catalogStore.seed(catalog)
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json")),
            catalog: catalogStore, configPath: { nil })
        controller.defaultBoard = { DefaultBoard.make(harnesses: ["claude"], canvasWidth: $0) }
        controller.open(configDirectory: root.appendingPathComponent("config").path)
        return controller
    }

    private var boardFile: URL { root.appendingPathComponent("config/boards/home.yml") }

    private let sourceBoard = """
        format: 1
        surface: home
        widgets:
          - id: disk
            title: Disk
            source: {kind: command, run: df, every: 60s}
            view: {kind: text}
            frame: {x: 24, y: 24, w: 320, h: 160}
            size: medium
            minimized: false
            z: 1
          - id: tail
            title: Log
            source: {kind: command, run: tail, args: [-f, /var/log/system.log], mode: stream}
            view: {kind: text}
            frame: {x: 24, y: 200, w: 320, h: 320}
            size: large
            minimized: true
            z: 2
          - id: clock
            title: Clock
            source: {kind: provider, name: app/clock, every: 60s}
            view: {kind: app.clock}
            frame: {x: 400, y: 24, w: 320, h: 160}
            size: medium
            minimized: false
            z: 3
        """

    func testSourceEntriesFollowMinimizeAndLeaveProvidersToTheRuntime() throws {
        let board = try BoardCodec.decode(sourceBoard)
        let entries = HomeBoardController.sourceEntries(
            board: board, resolve: { WidgetResolution.resolveInline($0) }, isOnScreen: { _ in true })
        XCTAssertEqual(entries.map(\.id), ["disk", "tail"])
        XCTAssertEqual(entries.map(\.isVisible), [true, false])
        XCTAssertEqual(entries.first?.source.needsApproval, true)
    }

    func testNothingIsVisibleWhenHomeIsNotOnScreen() throws {
        let board = try BoardCodec.decode(sourceBoard)
        let entries = HomeBoardController.sourceEntries(
            board: board, resolve: { WidgetResolution.resolveInline($0) }, isOnScreen: { _ in false })
        XCTAssertTrue(entries.allSatisfy { !$0.isVisible })
    }

    func testSourceWidgetsAreNotRuntimeJobs() throws {
        let controller = makeController()
        try sourceBoard.write(to: boardFile, atomically: true, encoding: .utf8)
        controller.start()
        controller.reload()
        XCTAssertEqual(controller.runtimeJobs().map(\.instanceID), ["clock"])
        XCTAssertEqual(controller.sourceEntries(isOnScreen: { _ in true }).map(\.id), ["disk", "tail"])
    }

    func testAnInlinePackageProviderIsCheckedAgainstTheLoadedCatalog() throws {
        let before = DemoData.widgetCatalog
        let catalog = WidgetCatalog(
            engine: before.engine, packagesRelease: before.packagesRelease, widgets: before.widgets, providers: [])
        let controller = makeController(catalog: catalog)
        try """
            format: 1
            surface: home
            widgets:
              - id: load
                title: Load
                source: {kind: provider, name: ghost/load, target: {machine: main}, every: 60s}
                view: {kind: number, value: "{{json.load}}"}
                frame: {x: 24, y: 24, w: 320, h: 160}
                size: medium
                minimized: false
                z: 1
            """.write(to: boardFile, atomically: true, encoding: .utf8)
        controller.start()
        controller.reload()
        let widget = try XCTUnwrap(controller.store?.board?.widgets.first)
        XCTAssertEqual(
            controller.resolution(of: widget),
            .refused(type: "load", reason: "source.name ghost/load: no package ghost in the release or your own packages"))
        XCTAssertEqual(controller.sourceEntries(isOnScreen: { _ in true }).map(\.id), [])
    }

    func testAnInlinePackageProviderNeitherRunsNorAsksUntilTheCatalogLoads() throws {
        try FileManager.default.createDirectory(at: boardFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            format: 1
            surface: home
            widgets:
              - id: load
                title: Load
                source: {kind: provider, name: acme-tools/load, target: {workspace: alice-dev}, every: 60s}
                view: {kind: number, value: "{{json.load}}"}
                frame: {x: 24, y: 24, w: 320, h: 160}
                size: medium
                minimized: false
                z: 1
            """.write(to: boardFile, atomically: true, encoding: .utf8)
        let store = WidgetCatalogStore(read: { throw DevmachineCLIError.commandFailed("not yet") })
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json")),
            catalog: store, configPath: { nil })
        controller.open(configDirectory: root.appendingPathComponent("config").path)
        let widget = try XCTUnwrap(controller.store?.board?.widgets.first)
        XCTAssertEqual(controller.resolution(of: widget), .waitingForCatalog(type: "load"))
        XCTAssertEqual(controller.sourceEntries(isOnScreen: { _ in true }).map(\.id), [])
        XCTAssertFalse(store.isWaitedFor)
        controller.syncCatalogWaits()
        XCTAssertTrue(store.isWaitedFor)

        let commit = String(repeating: "1", count: 40)
        store.seed(WidgetCatalog(
            engine: "1.3", packagesRelease: "v41", widgets: [],
            providers: [CatalogProvider(
                name: "acme-tools/load", spec: PackageProviderSpec(returns: ["load": "number"], minEvery: "10s"),
                trust: .thirdParty,
                packageSource: CatalogPackageSource(url: "https://example.com/acme/acme-tools.git", ref: "v1.2.0", commit: commit))]))
        guard case let .ready(resolved)? = controller.resolution(of: widget), let source = resolved.source else {
            return XCTFail("the loaded catalog resolves it")
        }
        XCTAssertEqual(source.packageCommit, commit)
        XCTAssertEqual(ApprovalPrompt(source, context: [:]).thirdPartySource, "https://example.com/acme/acme-tools.git")
        XCTAssertEqual(controller.sourceEntries(isOnScreen: { _ in true }).map(\.id), ["load"])
        controller.syncCatalogWaits()
        XCTAssertFalse(store.isWaitedFor)
    }

    func testAWidgetChangedWithinOneReleaseRefreshesTheJobs() {
        let before = DemoData.widgetCatalog
        let edited = WidgetCatalog(
            engine: before.engine, packagesRelease: before.packagesRelease, widgets: Array(before.widgets.dropLast()))
        XCTAssertNotEqual(
            HomeJobsTrigger(board: nil, catalog: before, visible: .zero),
            HomeJobsTrigger(board: nil, catalog: edited, visible: .zero))
    }

    func testTheLiveRunnersSendAPackageProviderToItsOwnRunner() {
        let source = WidgetSource.packageProvider(PackageProviderSource(
            name: "acme-tools/load", with: [:], target: .machine("main"), every: .interval(30), timeout: 30))
        XCTAssertTrue(WidgetSourceLive.runners().runner(for: source) is PackageProviderRunner)
    }

    func testAnInjectedSourceControllerIsTheOneUsed() {
        let sources = WidgetSourceController(
            runners: WidgetSourceLive.runners(),
            approvalsFile: WidgetApprovalsFile(fileURL: root.appendingPathComponent("approvals.json")),
            historyStore: SparklineHistoryStore(directory: root.appendingPathComponent("history")), isDemo: false)
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json")),
            catalog: WidgetCatalogStore(read: { DemoData.widgetCatalog }), sources: sources)
        XCTAssertTrue(controller.sources === sources)
    }

    private var genericUsage: CatalogWidget {
        CatalogWidget(
            name: "devmachine-app/usage",
            inputs: ["harness": CatalogInput(type: "choice", defaultValue: nil, summary: "", from: "harnesses")],
            source: CatalogSource(name: "app/harness-usage", with: ["harness": "{{inputs.harness}}"], every: "60s"),
            viewKind: "app.harness-usage", sizes: ["small", "medium", "wide"], defaultSize: "medium")
    }

    private var packageUsage: CatalogWidget {
        CatalogWidget(
            name: "claude-code/usage", source: CatalogSource(name: "app/harness-usage", with: ["harness": "claude"], every: "60s"),
            viewKind: "app.harness-usage", sizes: ["medium"], defaultSize: "medium")
    }

    private func usageEntries(_ controller: HomeBoardController) -> [String] {
        (controller.store?.board?.widgets ?? []).filter { $0.type.hasSuffix("/usage") }.map {
            if case let .string(value)? = $0.with["harness"] { return "\($0.type)#\(value)" }
            return "\($0.type)#bare"
        }
    }

    private func harnessValues(_ controller: HomeBoardController) -> [String?] {
        (controller.store?.board?.widgets ?? []).filter { $0.type == "devmachine-app/usage" }.map {
            if case let .string(value)? = $0.with["harness"] { return value }
            return nil
        }
    }

    func testAPackageUsageWidgetIsNotPlacedOverAHarnessTheBoardShows() {
        let controller = makeController(catalog: WidgetCatalog(engine: "1.5", packagesRelease: "r", widgets: [genericUsage, packageUsage]))
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude"])
        XCTAssertFalse(controller.store?.board?.widgets.contains { $0.type == "claude-code/usage" } ?? true)
    }

    func testEnablingAHarnessLaterAddsOneGenericUsageWidgetForIt() {
        let controller = makeController(catalog: WidgetCatalog(engine: "1.5", packagesRelease: "r", widgets: [genericUsage]))
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude"])
        XCTAssertEqual(harnessValues(controller), ["claude"])
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertEqual(harnessValues(controller), ["claude", "codex"])
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertEqual(harnessValues(controller), ["claude", "codex"])
    }

    func testARemovedHarnessWidgetIsNotAddedAgain() throws {
        let controller = makeController(catalog: WidgetCatalog(engine: "1.5", packagesRelease: "r", widgets: [genericUsage]))
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        let codex = controller.store?.board?.widgets.first { $0.with["harness"] == .string("codex") }
        controller.remove(try XCTUnwrap(codex).id)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertEqual(harnessValues(controller), ["claude"])
    }

    func testARemovedDefaultBoardWidgetIsNotPutBackInDemoStyleCatalogs() {
        let controller = makeController(
            catalog: WidgetCatalog(engine: "1.5", packagesRelease: "r", widgets: [genericUsage, packageUsage]))
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude"])
        controller.remove("claude-usage")
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude"])
        XCTAssertEqual(usageEntries(controller), [])
    }

    func testAnOldBoardWithAPerHarnessEntryGetsNoDuplicateAndNoBareEntry() {
        let controller = makeController(
            catalog: WidgetCatalog(engine: "1.5", packagesRelease: "r", widgets: [genericUsage, packageUsage]))
        controller.store?.update {
            $0.widgets = [BoardWidget(
                id: "claude-usage", type: "claude-code/usage", frame: BoardFrame(x: 24, y: 24, w: 320, h: 160), size: "medium", z: 1)]
        }
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude"])
        XCTAssertEqual(usageEntries(controller), ["claude-code/usage#bare"])
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertEqual(usageEntries(controller), ["claude-code/usage#bare", "devmachine-app/usage#codex"])
    }

    func testAHarnessTheContractDoesNotListGetsNoUsageWidget() {
        let controller = makeController(catalog: WidgetCatalog(engine: "1.5", packagesRelease: "r", widgets: [genericUsage]))
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "pi"])
        XCTAssertEqual(harnessValues(controller), ["claude"])
    }

    func testAUsageWidgetWithNoHarnessCountsAsTheFirstHarness() {
        let controller = makeController(catalog: WidgetCatalog(engine: "1.5", packagesRelease: "r", widgets: [genericUsage]))
        controller.store?.update {
            $0.widgets = [BoardWidget(
                id: "usage", type: "devmachine-app/usage", frame: BoardFrame(x: 24, y: 24, w: 320, h: 160), size: "medium", z: 1)]
        }
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertEqual(harnessValues(controller), [nil, "codex"])
    }

    func testAChoiceWidgetWithNoOptionsNeverPlacesABareCopy() {
        let controller = makeController(catalog: WidgetCatalog(engine: "1.5", packagesRelease: "r", widgets: [genericUsage]))
        controller.store?.update { $0.widgets = [] }
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: [])
        XCTAssertEqual(controller.store?.board?.widgets.count, 0)
    }

    func testTheDefaultBoardIsLaidOutForTheCanvasWidthKnownWhenItIsWritten() throws {
        let catalogStore = WidgetCatalogStore(read: { DemoData.widgetCatalog })
        catalogStore.seed(DemoData.widgetCatalog)
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json")),
            catalog: catalogStore, configPath: { nil })
        controller.defaultBoard = { DefaultBoard.make(harnesses: ["claude"], canvasWidth: $0) }
        controller.canvasWidth = 2000
        controller.open(configDirectory: root.appendingPathComponent("config").path)
        let clock = try XCTUnwrap(controller.store?.board?.widgets.first { $0.id == "clock" })
        XCTAssertEqual(clock.frame.x + clock.frame.w, 1976)
    }

    func testOpeningWritesTheDefaultBoard() throws {
        let controller = makeController()
        XCTAssertEqual(controller.store?.board?.widgets.map(\.id), ["machines", "clock", "summary", "claude-usage"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: boardFile.path))
    }

    func testPlacesAddsOnlyEligibleWidgetsAndRemembersThem() throws {
        let controller = makeController()
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude"])
        let types = controller.store?.board?.widgets.map(\.type) ?? []
        XCTAssertFalse(types.contains("codex/usage"))
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertTrue(controller.store?.board?.widgets.map(\.type).contains("codex/usage") ?? false)
        let added = try XCTUnwrap(controller.store?.board?.widgets.first { $0.type == "codex/usage" })
        controller.remove(added.id)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertFalse(controller.store?.board?.widgets.map(\.type).contains("codex/usage") ?? true)
    }

    func testCanvasActionsChangeTheBoard() throws {
        let controller = makeController()
        controller.move("clock", to: BoardFrame(x: 400, y: 48, w: 320, h: 160))
        controller.setPreset("summary", preset: "medium")
        controller.setMinimized("machines", true)
        controller.bringToFront("clock")
        controller.resize("claude-usage", to: BoardFrame(x: 24, y: 360, w: 336, h: 160), auto: false, sizes: ["small", "medium", "wide"])
        let board = try XCTUnwrap(controller.store?.board)
        let byID = Dictionary(uniqueKeysWithValues: board.widgets.map { ($0.id, $0) })
        XCTAssertEqual(byID["clock"]?.frame, BoardFrame(x: 400, y: 48, w: 320, h: 160))
        XCTAssertEqual(byID["clock"]?.z, 5)
        XCTAssertEqual(byID["summary"]?.size, "medium")
        XCTAssertEqual(byID["summary"]?.frame.w, 320)
        XCTAssertEqual(byID["machines"]?.minimized, true)
        XCTAssertEqual(byID["claude-usage"]?.size, "custom")
        controller.store?.flush()
        XCTAssertEqual(try BoardCodec.decode(String(contentsOf: boardFile, encoding: .utf8)), board)
    }

    func testPlacingXsMovesOnlyThoseWidgetsSideways() throws {
        let controller = makeController()
        let before = Dictionary(uniqueKeysWithValues: (controller.store?.board?.widgets ?? []).map { ($0.id, $0.frame) })
        controller.placeX(["clock": 512, "summary": 520])
        let after = Dictionary(uniqueKeysWithValues: (controller.store?.board?.widgets ?? []).map { ($0.id, $0.frame) })
        XCTAssertEqual(after["clock"]?.x, 512)
        XCTAssertEqual(after["clock"]?.y, before["clock"]?.y)
        XCTAssertEqual(after["summary"]?.x, 520)
        XCTAssertEqual(after["machines"], before["machines"])
    }

    func testAGrowingWidgetResizedToItsContentGoesBackToAuto() throws {
        let controller = makeController()
        controller.resize(
            "summary", to: BoardFrame(x: 920, y: 336, w: 336, h: 48), auto: true, sizes: ["medium", "wide"])
        let summary = try XCTUnwrap(controller.store?.board?.widgets.first { $0.id == "summary" })
        XCTAssertEqual(summary.size, "auto")
        XCTAssertEqual(summary.frame, BoardFrame(x: 920, y: 336, w: 336, h: 0))
    }

    func testResizingAnAutoWidgetShorterStoresTheHeightAsACap() throws {
        let controller = makeController()
        controller.resize(
            "machines", to: BoardFrame(x: 24, y: 24, w: 576, h: 120), auto: false, sizes: ["medium", "large", "tall"])
        let machines = try XCTUnwrap(controller.store?.board?.widgets.first { $0.id == "machines" })
        XCTAssertEqual(machines.size, "custom")
        XCTAssertEqual(machines.frame, BoardFrame(x: 24, y: 24, w: 576, h: 120))
    }

    func testTheSizeMenuAutoKeepsThePlaceAndWidthAndDropsTheHeight() throws {
        let controller = makeController()
        controller.setPreset("machines", preset: "large")
        controller.setPreset("machines", preset: "auto")
        let machines = try XCTUnwrap(controller.store?.board?.widgets.first { $0.id == "machines" })
        XCTAssertEqual(machines.size, "auto")
        XCTAssertEqual(machines.frame, BoardFrame(x: 24, y: 24, w: 320, h: 0))
    }

    func testAPresetOnAnAutoWidgetGivesItsHeightBack() throws {
        let controller = makeController()
        controller.setPreset("summary", preset: "medium")
        let summary = try XCTUnwrap(controller.store?.board?.widgets.first { $0.id == "summary" })
        XCTAssertEqual(summary.size, "medium")
        XCTAssertEqual(summary.frame, BoardFrame(x: 920, y: 336, w: 320, h: 160))
    }

    func testResetSizeReturnsAGrowingWidgetToAutoAndAFixedOneToItsDefaultPreset() throws {
        let controller = makeController()
        controller.resize("summary", to: BoardFrame(x: 920, y: 336, w: 400, h: 64), auto: false, sizes: ["medium", "wide"])
        controller.resize("clock", to: BoardFrame(x: 840, y: 24, w: 416, h: 296), auto: false, sizes: ["small", "medium", "wide"])
        controller.resetSize("summary")
        controller.resetSize("clock")
        let byID = Dictionary(uniqueKeysWithValues: (controller.store?.board?.widgets ?? []).map { ($0.id, $0) })
        XCTAssertEqual(byID["summary"]?.size, "auto")
        XCTAssertEqual(byID["summary"]?.frame, BoardFrame(x: 920, y: 336, w: 640, h: 0))
        XCTAssertEqual(byID["clock"]?.size, "medium")
        XCTAssertEqual(byID["clock"]?.frame, BoardFrame(x: 840, y: 24, w: 320, h: 160))
        XCTAssertEqual(byID["clock"]?.z, 2)
    }

    func testResetSizeOfAnUnknownWidgetChangesNothing() {
        let controller = makeController()
        let before = controller.store?.board
        controller.resetSize("ghost")
        XCTAssertEqual(controller.store?.board, before)
    }

    func testBringingTheTopWidgetToFrontChangesNothing() throws {
        let controller = makeController()
        controller.bringToFront("claude-usage")
        XCTAssertEqual(controller.store?.board?.widgets.first { $0.id == "claude-usage" }?.z, 4)
    }

    func testAddingAWidgetPutsItOnAFreeSpotAndRemembersIt() throws {
        let controller = makeController()
        let codex = try XCTUnwrap(DemoData.widgetCatalog.widget(named: "codex/usage"))
        controller.add(codex, canvasWidth: 1280)
        let added = try XCTUnwrap(controller.store?.board?.widgets.first { $0.type == "codex/usage" })
        XCTAssertEqual(added.z, 5)
        controller.remove(added.id)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertFalse(controller.store?.board?.widgets.map(\.type).contains("codex/usage") ?? true)
    }

    func testResetBacksUpAndForgetsHomePlacements() throws {
        let controller = makeController()
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        controller.store?.flush()
        let before = try Data(contentsOf: boardFile)
        try controller.resetHome()
        XCTAssertEqual(try Data(contentsOf: boardFile.appendingPathExtension("bak")), before)
        XCTAssertEqual(controller.store?.board?.widgets.map(\.id), ["machines", "clock", "summary", "claude-usage"])
        let placements = WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json")).load()
        XCTAssertFalse(placements.contains("codex/usage", on: "home"))
    }

    func testHomeSavesKeepTheStackPlacements() throws {
        let controller = makeController()
        let file = WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json"))
        var stack = WidgetPlacements()
        stack.insert("devmachine-app/links", on: "context-sidebar")
        try file.save(stack, surface: "context-sidebar")
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertTrue(file.load().contains("codex/usage", on: "home"))
        XCTAssertTrue(file.load().contains("devmachine-app/links", on: "context-sidebar"))
        try controller.resetHome()
        XCTAssertFalse(file.load().contains("codex/usage", on: "home"))
        XCTAssertTrue(file.load().contains("devmachine-app/links", on: "context-sidebar"))
    }

    func testResetWithoutAConfigurationFails() {
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json")),
            catalog: WidgetCatalogStore(read: { DemoData.widgetCatalog }))
        XCTAssertThrowsError(try controller.resetHome()) { error in
            XCTAssertEqual(error as? HomeBoardError, .noConfiguration)
        }
    }

    func testAMinimizedWidgetHasAnInactiveJob() throws {
        let controller = makeController()
        controller.setMinimized("claude-usage", true)
        let job = try XCTUnwrap(controller.runtimeJobs().first { $0.instanceID == "claude-usage" })
        XCTAssertFalse(job.isActive)
        XCTAssertEqual(job.key, WidgetRefreshKey(provider: "app/harness-usage", args: ["harness": "claude"]))
    }

    func testAWidgetOffScreenHasAnInactiveJob() throws {
        let controller = makeController()
        let jobs = controller.runtimeJobs(isOnScreen: { $0.id != "clock" })
        XCTAssertEqual(jobs.first { $0.instanceID == "clock" }?.isActive, false)
        XCTAssertEqual(jobs.first { $0.instanceID == "summary" }?.isActive, true)
    }

    func testDemoUsageWidgetsFixTheirHarness() throws {
        let codex = try XCTUnwrap(DemoData.widgetCatalog.widget(named: "codex/usage"))
        XCTAssertTrue(codex.inputs.isEmpty)
        XCTAssertEqual(codex.source.name, "app/harness-usage")
        XCTAssertEqual(WidgetPlacer.harness(of: codex), "codex")
    }

    func testReloadReadsTheCatalogAgain() async throws {
        let reads = ReadCounter()
        let catalog = DemoData.widgetCatalog
        let store = WidgetCatalogStore(read: {
            reads.increment()
            return catalog
        })
        let controller = makeController(store: store)
        controller.reload()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reads.value, 0)
        controller.start()
        XCTAssertEqual(reads.value, 0)
        controller.reload()
        try await waitUntil { reads.value == 1 }
    }

    func testABoardsFolderDeletedAndRecreatedIsStillWatched() async throws {
        let controller = makeController()
        try FileManager.default.removeItem(at: boardFile.deletingLastPathComponent())
        try await waitUntil { FileManager.default.fileExists(atPath: self.boardFile.path) }
        let edited = Board(surface: "home", widgets: [
            BoardWidget(id: "clock", type: "devmachine-app/clock",
                        frame: BoardFrame(x: 24, y: 24, w: 320, h: 160), size: "medium", z: 1),
        ])
        try Data(BoardCodec.encode(edited).utf8).write(to: boardFile, options: .atomic)
        try await waitUntil { controller.store?.board == edited }
    }

    func testAFailedPlacementsSaveIsReportedAndKeptInMemory() throws {
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)
        let catalogStore = WidgetCatalogStore(read: { DemoData.widgetCatalog })
        catalogStore.seed(DemoData.widgetCatalog)
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: blocker.appendingPathComponent("widget-placements.json")),
            catalog: catalogStore)
        controller.defaultBoard = { _ in DefaultBoard.make(harnesses: []) }
        controller.open(configDirectory: root.appendingPathComponent("config").path)
        XCTAssertNil(controller.placementsError)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertNotNil(controller.placementsError)
        let added = try XCTUnwrap(controller.store?.board?.widgets.first { $0.type == "codex/usage" })
        controller.remove(added.id)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertFalse(controller.store?.board?.widgets.map(\.type).contains("codex/usage") ?? true)
    }

    func testASuccessfulPlacementsSaveClearsTheError() throws {
        let folder = root.appendingPathComponent("support")
        try Data("x".utf8).write(to: folder)
        let catalogStore = WidgetCatalogStore(read: { DemoData.widgetCatalog })
        catalogStore.seed(DemoData.widgetCatalog)
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: folder.appendingPathComponent("widget-placements.json")),
            catalog: catalogStore)
        controller.defaultBoard = { _ in DefaultBoard.make(harnesses: []) }
        controller.open(configDirectory: root.appendingPathComponent("config").path)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude"])
        XCTAssertNotNil(controller.placementsError)
        try FileManager.default.removeItem(at: folder)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertNil(controller.placementsError)
    }

    func testDismissingThePlacementsErrorHidesIt() throws {
        let folder = root.appendingPathComponent("support")
        try Data("x".utf8).write(to: folder)
        let catalogStore = WidgetCatalogStore(read: { DemoData.widgetCatalog })
        catalogStore.seed(DemoData.widgetCatalog)
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: folder.appendingPathComponent("widget-placements.json")),
            catalog: catalogStore)
        controller.defaultBoard = { _ in DefaultBoard.make(harnesses: []) }
        controller.open(configDirectory: root.appendingPathComponent("config").path)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude"])
        XCTAssertNotNil(controller.placementsError)
        controller.dismissPlacementsError()
        XCTAssertNil(controller.placementsError)
    }

    func testAddingToABrokenBoardFailsAndChangesNothing() throws {
        try FileManager.default.createDirectory(at: boardFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("widgets: [unclosed\n".utf8).write(to: boardFile)
        let controller = makeController()
        let before = try String(contentsOf: boardFile, encoding: .utf8)
        let clock = try XCTUnwrap(DemoData.widgetCatalog.widgets.first { $0.name == "devmachine-app/clock" })
        XCTAssertFalse(controller.add(clock, canvasWidth: 1280))
        XCTAssertEqual(try String(contentsOf: boardFile, encoding: .utf8), before)
        XCTAssertEqual(controller.addBlockedReason, HomeBoardCopy.invalidNote)
    }

    func testAddingToAnOpenBoardSucceeds() throws {
        let controller = makeController()
        let clock = try XCTUnwrap(DemoData.widgetCatalog.widgets.first { $0.name == "devmachine-app/clock" })
        XCTAssertNil(controller.addBlockedReason)
        XCTAssertTrue(controller.add(clock, canvasWidth: 1280))
        XCTAssertEqual(controller.store?.board?.widgets.filter { $0.type == "devmachine-app/clock" }.count, 2)
    }

    func testAddingBeforeTheBoardIsOpenFails() throws {
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json")),
            catalog: WidgetCatalogStore(read: { DemoData.widgetCatalog }))
        let clock = try XCTUnwrap(DemoData.widgetCatalog.widgets.first { $0.name == "devmachine-app/clock" })
        XCTAssertFalse(controller.add(clock, canvasWidth: 1280))
        XCTAssertEqual(controller.addBlockedReason, "Home is not ready yet.")
    }

    func testReloadOpensTheBoardOnceTheConfigurationIsKnown() async throws {
        let configPath = root.appendingPathComponent("config").path
        let answers = ConfigAnswers([nil, configPath])
        let catalogStore = WidgetCatalogStore(read: { DemoData.widgetCatalog })
        catalogStore.seed(DemoData.widgetCatalog)
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: root.appendingPathComponent("widget-placements.json")),
            catalog: catalogStore,
            configPath: { answers.next() })
        controller.defaultBoard = { _ in DefaultBoard.make(harnesses: []) }
        controller.start()
        try await waitUntil { answers.calls == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(controller.store)
        controller.reload()
        try await waitUntil { controller.store != nil }
        XCTAssertEqual(controller.store?.fileURL, boardFile)
        controller.reload()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(answers.calls, 2)
    }

    func testResetWithoutAConfigurationFolderKeepsThePlacements() throws {
        let controller = makeController()
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        let placementsURL = root.appendingPathComponent("widget-placements.json")
        let before = try Data(contentsOf: placementsURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("config"))
        XCTAssertThrowsError(try controller.resetHome()) { error in
            XCTAssertEqual(error as? HomeBoardError, .noConfigurationFolder)
        }
        XCTAssertEqual(try Data(contentsOf: placementsURL), before)
        XCTAssertTrue(WidgetPlacementsFile(fileURL: placementsURL).load().contains("codex/usage", on: "home"))
        let codexCount = controller.store?.board?.widgets.filter { $0.type == "codex/usage" }.count
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertEqual(controller.store?.board?.widgets.filter { $0.type == "codex/usage" }.count, codexCount)
    }

    func testAResetClearsThePlacementsError() throws {
        let support = root.appendingPathComponent("support")
        try Data("x".utf8).write(to: support)
        let catalogStore = WidgetCatalogStore(read: { DemoData.widgetCatalog })
        catalogStore.seed(DemoData.widgetCatalog)
        let placementsURL = support.appendingPathComponent("widget-placements.json")
        let controller = HomeBoardController(
            placementsFile: WidgetPlacementsFile(fileURL: placementsURL), catalog: catalogStore)
        controller.defaultBoard = { _ in DefaultBoard.make(harnesses: []) }
        controller.open(configDirectory: root.appendingPathComponent("config").path)
        controller.applyPlaces(canvasWidth: 1280, enabledHarnesses: ["claude", "codex"])
        XCTAssertNotNil(controller.placementsError)
        try FileManager.default.removeItem(at: support)
        try controller.resetHome()
        XCTAssertNil(controller.placementsError)
        XCTAssertFalse(WidgetPlacementsFile(fileURL: placementsURL).load().contains("codex/usage", on: "home"))
    }

    func testThePlacementsFileCanBeMoved() {
        XCTAssertEqual(
            HomeBoardController.placementsURL(environment: ["DEVMACHINE_WIDGET_PLACEMENTS": "/tmp/dm/p.json"]).path,
            "/tmp/dm/p.json")
        XCTAssertEqual(HomeBoardController.placementsURL(environment: [:]), WidgetPlacementsFile.defaultFileURL)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met within \(timeout)s") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class ConfigAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String?]
    private var count = 0

    init(_ answers: [String?]) { self.answers = answers }

    var calls: Int { lock.withLock { count } }

    func next() -> String? {
        lock.withLock {
            count += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }
}
