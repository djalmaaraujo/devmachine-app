import Foundation
import DevmachineCore
import os

enum HomeBoardError: LocalizedError, Equatable {
    case noConfiguration
    case noConfigurationFolder

    var errorDescription: String? {
        switch self {
        case .noConfiguration:
            "Home has no layout file yet: the devmachine CLI has not said where its configuration lives."
        case .noConfigurationFolder:
            "Home was not reset: the devmachine configuration folder does not exist yet."
        }
    }
}

/// Home's board: the file, the catalog that gives each entry its meaning,
/// the once-only placements, and the refresh schedule.
@MainActor
final class HomeBoardController: ObservableObject {
    static let shared = HomeBoardController()

    @Published private(set) var store: BoardStore?
    @Published private(set) var placementsError: String?
    let catalog: WidgetCatalogStore
    let runtime = WidgetRuntimeDriver()
    var canvasWidth = 1280
    var defaultBoard: @MainActor (_ canvasWidth: Int) -> Board = { DefaultBoard.make(harnesses: [], canvasWidth: $0) }

    private let placementsFile: WidgetPlacementsFile
    private var placements: WidgetPlacements
    private var watcher: BoardFileWatcher?
    private var watchedFolder: UInt64?
    private var configObserver: NSObjectProtocol?
    private var started = false
    private var openingFromConfiguration = false
    private let configPath: @Sendable () async -> String?
    private var injectedSources: WidgetSourceController?
    private static let log = Logger(subsystem: "app.devmachine.mac", category: "widgets")

    init(
        placementsFile: WidgetPlacementsFile = WidgetPlacementsFile(fileURL: HomeBoardController.placementsURL()),
        catalog: WidgetCatalogStore = .shared,
        configPath: @escaping @Sendable () async -> String? = {
            await Task.detached { try? DevmachineCLI.resolve().configPath().path }.value
        },
        sources: WidgetSourceController? = nil
    ) {
        self.placementsFile = placementsFile
        self.placements = placementsFile.load()
        self.catalog = catalog
        self.configPath = configPath
        self.injectedSources = sources
    }

    /// Created on first use, so tests that never touch source widgets never
    /// read the real approvals file.
    var sources: WidgetSourceController {
        if let injectedSources { return injectedSources }
        let created = WidgetSourceController(runners: WidgetSourceLive.runners())
        injectedSources = created
        return created
    }

    static func placementsURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["DEVMACHINE_WIDGET_PLACEMENTS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return WidgetPlacementsFile.defaultFileURL
    }

    func start() {
        guard !started else { return }
        started = true
        if DemoMode.isActive {
            catalog.pin(DemoData.widgetCatalog)
            open(configDirectory: DemoMode.boardsFolder)
            return
        }
        catalog.reloadIfIdle()
        observeConfiguration()
        openFromConfiguration()
    }

    /// Asks the CLI where its configuration lives; a reload asks again while
    /// no board is open, so a CLI installed after launch is picked up.
    func openFromConfiguration() {
        guard store == nil, !openingFromConfiguration else { return }
        openingFromConfiguration = true
        Task {
            let path = await configPath()
            openingFromConfiguration = false
            if let path, store == nil { open(configDirectory: path) }
        }
    }

    func open(configDirectory: String) {
        let store = BoardStore(
            fileURL: BoardStore.homeFileURL(configDirectory: configDirectory),
            makeDefault: { [weak self] in
                guard let self else { return DefaultBoard.make(harnesses: []) }
                return self.defaultBoard(self.canvasWidth)
            })
        watcher = nil
        watchedFolder = nil
        self.store = store
        store.load()
        watchIfNeeded(store)
    }

    /// After the packages change: the catalog may have new widgets, and the
    /// board file may have been rewritten.
    func reload() {
        guard started else { return }
        catalog.reloadSoon()
        reloadBoard()
    }

    private func reloadBoard() {
        guard let store else { return openFromConfiguration() }
        store.load()
        watchIfNeeded(store)
    }

    /// The watcher holds the `boards/` folder it opened, so once that folder
    /// is deleted it hears nothing more, even after a new one appears.
    private func watchIfNeeded(_ store: BoardStore) {
        let folder = Self.fileNumber(store.fileURL.deletingLastPathComponent())
        guard watcher == nil || folder != watchedFolder else { return }
        watchedFolder = folder
        watcher = folder == nil ? nil : BoardFileWatcher(fileURL: store.fileURL) { [weak self] in self?.reloadBoard() }
    }

    private static func fileNumber(_ url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private func observeConfiguration() {
        configObserver = NotificationCenter.default.addObserver(
            forName: ConfigDirectoryWatcher.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func resolution(of widget: BoardWidget) -> WidgetResolution? {
        if widget.isInline { return WidgetResolution.resolveInline(widget, catalog: catalog.catalog) }
        return catalog.catalog.map { WidgetResolution.resolve(widget, in: $0) }
    }

    func applyPlaces(canvasWidth: Int, enabledHarnesses: Set<String>) {
        self.canvasWidth = canvasWidth
        guard let store, store.canEdit, let board = store.board, let catalog = catalog.catalog else { return }
        let firstHarness = enabledHarnesses.sorted().first
        let shown: Set<String> = Set(board.widgets.compactMap { (widget: BoardWidget) -> String? in
            guard case let .ready(resolved)? = resolution(of: widget), resolved.provider == "app/harness-usage" else { return nil }
            let harness = resolved.arguments["harness"] ?? ""
            return harness.isEmpty ? firstHarness : harness
        })
        let result = WidgetPlacer.place(
            on: board, catalog: catalog, placements: placements, canvasWidth: canvasWidth,
            options: ["harnesses": enabledHarnesses.sorted()],
            isShown: { widget in WidgetPlacer.harness(of: widget).map(shown.contains) ?? false },
            isEligible: { widget in WidgetPlacer.harness(of: widget).map(enabledHarnesses.contains) ?? true })
        if result.boardChanged { store.update { $0 = result.board } }
        if result.placementsChanged { savePlacements(result.placements) }
    }

    func move(_ id: String, to frame: BoardFrame) {
        edit(id) { $0.frame = frame }
    }

    func placeX(_ xs: [String: Int]) {
        guard !xs.isEmpty else { return }
        store?.update { board in
            for index in board.widgets.indices {
                if let x = xs[board.widgets[index].id] { board.widgets[index].frame.x = x }
            }
        }
    }

    func resize(_ id: String, to frame: BoardFrame, auto: Bool, sizes: [String]) {
        edit(id) {
            if auto {
                $0.frame = BoardFrame(x: frame.x, y: frame.y, w: frame.w, h: 0)
                $0.size = BoardWidget.autoSize
            } else {
                $0.frame = frame
                $0.size = CanvasLayout.sizeName(CanvasSize(w: frame.w, h: frame.h), sizes: sizes)
            }
        }
    }

    func setPreset(_ id: String, preset: String) {
        if preset == BoardWidget.autoSize {
            edit(id) {
                $0.frame.h = 0
                $0.size = BoardWidget.autoSize
            }
            return
        }
        guard let size = CanvasLayout.presetSize(preset) else { return }
        edit(id) {
            $0.frame.w = size.w
            $0.frame.h = size.h
            $0.size = preset
        }
    }

    func resetSize(_ id: String) {
        guard case let .ready(resolved)? = store?.board?.widgets.first(where: { $0.id == id }).flatMap(resolution(of:))
        else { return }
        let sizes = resolved.widget.sizes
        let defaultSize = resolved.widget.defaultSize.isEmpty ? sizes.first ?? "medium" : resolved.widget.defaultSize
        edit(id) { $0 = CanvasLayout.reset($0, defaultSize: defaultSize, grows: resolved.grows) }
    }

    func setMinimized(_ id: String, _ minimized: Bool) {
        edit(id) { $0.minimized = minimized }
    }

    func bringToFront(_ id: String) {
        guard let board = store?.board, let widget = board.widgets.first(where: { $0.id == id }),
              board.widgets.contains(where: { $0.id != id && $0.z >= widget.z })
        else { return }
        let top = board.topZ
        edit(id) { $0.z = top + 1 }
    }

    func remove(_ id: String) {
        store?.update { $0.widgets.removeAll { $0.id == id } }
    }

    var addBlockedReason: String? {
        HomeBoardCopy.addBlocked(isOpen: store != nil, canEdit: store?.canEdit ?? false)
    }

    @discardableResult
    func add(_ widget: CatalogWidget, canvasWidth: Int) -> Bool {
        guard let store, store.canEdit, let board = store.board else { return false }
        let instance = WidgetPlacer.newInstance(of: widget, on: board, canvasWidth: canvasWidth, catalog: catalog.catalog)
        store.update { $0.widgets.append(instance) }
        var next = placements
        next.insert(widget.name, on: board.surface)
        savePlacements(next)
        return true
    }

    func dismissPlacementsError() {
        placementsError = nil
    }

    func resetHome() throws {
        guard let store else { throw HomeBoardError.noConfiguration }
        guard try store.reset() else { throw HomeBoardError.noConfigurationFolder }
        var next = placements
        next.reset(store.surface)
        placements = next
        logSetAside(try placementsFile.save(next, surface: store.surface))
        placementsError = nil
    }

    private func logSetAside(_ broken: URL?) {
        guard let broken else { return }
        Self.log.error("widget placements file did not decode; moved it to \(broken.path, privacy: .public)")
    }

    func syncCatalogWaits() {
        let waits = store?.board?.widgets.contains { resolution(of: $0)?.waitsForCatalog == true } ?? false
        catalog.setWaitsForCatalog(waits, board: DefaultBoard.surface)
    }

    func runtimeJobs(isOnScreen: (BoardWidget) -> Bool = { _ in true }) -> [WidgetJob] {
        guard let board = store?.board else { return [] }
        return board.widgets.compactMap { widget in
            guard case let .ready(resolved)? = resolution(of: widget), resolved.source == nil else { return nil }
            return AppWidgetJobs.job(for: widget, resolved: resolved, isOnScreen: isOnScreen(widget))
        }
    }

    func sourceEntries(isOnScreen: (BoardWidget) -> Bool) -> [SourceWidgetEntry] {
        guard let board = store?.board else { return [] }
        return Self.sourceEntries(board: board, resolve: resolution(of:), isOnScreen: isOnScreen)
    }

    static func sourceEntries(
        board: Board, resolve: (BoardWidget) -> WidgetResolution?, isOnScreen: (BoardWidget) -> Bool
    ) -> [SourceWidgetEntry] {
        board.widgets.compactMap { widget in
            guard case let .ready(resolved)? = resolve(widget), let source = resolved.source else { return nil }
            return SourceWidgetEntry(id: widget.id, source: source, isVisible: isOnScreen(widget) && !widget.minimized)
        }
    }

    private func edit(_ id: String, _ change: (inout BoardWidget) -> Void) {
        store?.update { board in
            guard let index = board.widgets.firstIndex(where: { $0.id == id }) else { return }
            change(&board.widgets[index])
        }
    }

    private func savePlacements(_ next: WidgetPlacements) {
        placements = next
        do {
            logSetAside(try placementsFile.save(next, surface: DefaultBoard.surface))
            placementsError = nil
        } catch {
            Self.log.error("saving widget placements failed: \(error.localizedDescription, privacy: .public)")
            placementsError = error.localizedDescription
        }
    }
}

extension HomeBoardController: WidgetEditTarget {
    var editSurface: String { DefaultBoard.surface }
    var editFileName: String { "home.yml" }
    var canEdit: Bool { store?.canEdit ?? false }
    var editCatalog: WidgetCatalog? { catalog.catalog }

    func editableEntry(_ id: String) -> EditableEntry? {
        store?.board?.widgets.first { $0.id == id }.map(EditableEntry.init)
    }

    func problem(with edit: EntryEdit, for id: String) -> String? {
        guard let catalog = catalog.catalog, let old = store?.board?.widgets.first(where: { $0.id == id }) else { return nil }
        var widget = old
        guard edit.apply(to: &widget) else { return nil }
        let reason = { (widget: BoardWidget) -> String? in
            if case let .refused(_, reason) = WidgetResolution.resolve(widget, in: catalog) { return reason }
            return nil
        }
        let after = edit.undeclaredInput(for: widget, in: catalog) ?? reason(widget)
        return after == reason(old) ? nil : after
    }

    @discardableResult
    func apply(_ edit: EntryEdit, to id: String) -> Bool {
        guard problem(with: edit, for: id) == nil else { return false }
        guard let store, store.canEdit, let board = store.board,
              let index = board.widgets.firstIndex(where: { $0.id == id })
        else { return false }
        var widget = board.widgets[index]
        guard edit.apply(to: &widget) else { return false }
        store.update { $0.widgets[index] = widget }
        return true
    }

    func addInline(_ inline: InlineWidget, title: String, preset: String) -> String? {
        guard let store, store.canEdit, let board = store.board else { return nil }
        let id = board.uniqueID(base: title)
        let widget = InlineEntryPlacement.canvasWidget(
            id: id, inline: inline, preset: preset, on: board, canvasWidth: canvasWidth, catalog: catalog.catalog)
        store.update { $0.widgets.append(widget) }
        return id
    }
}
