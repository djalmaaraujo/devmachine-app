#if DEBUG
import SwiftUI
import AppKit
import DevmachineCore

/// Debug builds only. The website's short loops, for
/// `DEVMACHINE_DEMO_WALK=site`: six scenes, each a run of frames written to
/// `<scene>/NNN.png` with a `frames.ffconcat` beside them that says how long
/// each frame stays on screen. `scripts/site_demo_videos.sh` turns each
/// scene into a video. Every frame is the real window in a state the app can
/// reach, drawn from demo data; nothing runs. A bitmap capture has no
/// pointer, so the walk draws one, with a short label where a step needs one.
@MainActor
enum DemoSiteWalk {
    /// A point on a control that marks itself with `demoClickTarget`;
    /// `sheet:` ids sit in the sheet or popover drawn over the window.
    struct Spot: Equatable {
        enum Place: Equatable { case center, header, bottomTrailing }

        let target: String
        var place: Place = .center
    }

    enum Pointer: Equatable {
        /// Moves there and clicks.
        case click(Spot, secondary: Bool = false)
        /// Moves there.
        case hover(Spot)
        /// Stays on the spot as it moves, the way a drag carries it.
        case follow(Spot)

        var spot: Spot {
            switch self {
            case let .click(spot, _), let .hover(spot), let .follow(spot): return spot
            }
        }

        var seconds: Double {
            switch self {
            case .click: return DemoPointer.clickSeconds
            case .hover: return DemoPointer.moveSeconds
            case .follow: return 0
            }
        }
    }

    /// One short caption, beside a control or at a point in the window.
    struct Label: Equatable {
        let text: String
        var near: String?
        /// Beside the control's bottom-right corner rather than its top.
        var byCorner = false
        /// Under the control, its trailing edge lined up with the control's.
        var below = false
        /// Its leading edge here.
        var at: CGPoint?
        /// Its trailing edge here.
        var endingAt: CGPoint?
    }

    struct Frame: Equatable {
        let step: Step
        /// Seconds the frame stays on screen in the video.
        let hold: Double
        var pointer: Pointer?
        var label: Label?
        /// The control the camera centres on, zoomed in; nil shows the whole
        /// window.
        var zoom: String?
    }

    enum Step: Equatable {
        case operatorChooser, operatorPick, operatorChat(Int)
        case sidebar, sessionGrid, gridMove, gridHalf, gridFull, gridRestore
        case cli(Int)
        case context(Int)
        case publishedApps, publishing, published
        case scheduledList, scheduledDetail, scheduledOutput, scheduledNew
        case shareStart, shareSheet, shareLink, shared, chat, guestReply, ownerReply
        case homeStart, homeDrag(Int), homeResize(Int), homeGallery, homeAdded
    }

    struct Scene: Equatable {
        let id: String
        let frames: [Frame]

        var seconds: Double {
            var zoom: String?
            var total = 0.0
            for frame in frames {
                if frame.zoom != zoom { total += DemoCamera.seconds }
                zoom = frame.zoom
                total += frame.hold + (frame.pointer?.seconds ?? 0)
            }
            return total
        }
    }

    static let windowSize = NSSize(width: 1600, height: 1000)

    private static let acmeClaude = "session:acme-devmachine/claude — payments refactor"
    private static let operatorLabelPoint = CGPoint(x: 1010, y: 96)
    private static let operatorAnswerLabelPoint = CGPoint(x: 1010, y: 560)
    /// Where the pointer waits at the start of a scene: clear of the
    /// terminal's text and of the labels.
    private static let restingPointer = CGPoint(x: 1180, y: 770)
    static let homeDragFrames = 8
    static let homeResizeFrames = 6

    static let scenes: [Scene] = [
        operatorScene, sessionsScene, cliScene, contextScene, publishScene, scheduledScene, shareScene, homeScene,
    ]

    private static let pickLabel = Label(text: "Pick your coding agent", at: CGPoint(x: 295, y: 340))

    private static let operatorScene = Scene(id: "operator", frames: [
        Frame(step: .operatorChooser, hold: 1.4, label: pickLabel),
        Frame(step: .operatorChooser, hold: 0.6, pointer: .hover(Spot(target: "operator:Claude Code")), label: pickLabel),
        Frame(step: .operatorPick, hold: 1.0, pointer: .click(Spot(target: "operator:Claude Code"))),
    ] + operatorPlayed.indices.map { index in
        let played = operatorPlayed[index]
        let point = played.label == answerLabel ? operatorAnswerLabelPoint : operatorLabelPoint
        return Frame(step: .operatorChat(index), hold: played.hold, label: played.label.map { Label(text: $0, at: point) })
    })

    private static let gridCell = "claude — payments refactor"

    private static let sessionsScene = Scene(id: "sessions", frames: [
        Frame(step: .sidebar, hold: 0.7),
        Frame(step: .sessionGrid, hold: 1.2, pointer: .click(Spot(target: "grid:acme-devmachine"))),
        Frame(
            step: .gridMove, hold: 2.0, pointer: .click(Spot(target: "grid-right:\(gridCell)")),
            label: Label(text: "Move it with its icons", near: "grid-right:\(gridCell)", below: true)),
        Frame(
            step: .gridHalf, hold: 1.4, pointer: .click(Spot(target: "grid-size:\(gridCell)")),
            label: Label(text: "Resize a cell: auto, half, full", near: "grid-size:\(gridCell)", below: true)),
        Frame(
            step: .gridFull, hold: 2.4, pointer: .click(Spot(target: "grid-size:\(gridCell)")),
            label: Label(text: "Give one the full width", near: "grid-size:\(gridCell)", below: true)),
        Frame(
            step: .gridRestore, hold: 2.6, pointer: .click(Spot(target: "grid-size:\(gridCell)")),
            label: Label(text: "And back to the grid", near: "grid-size:\(gridCell)", below: true)),
    ])

    private static let cliScene = Scene(id: "cli", frames: cliPlayed.indices.map { index in
        let played = cliPlayed[index]
        return Frame(
            step: .cli(index), hold: played.hold, label: played.label.map { Label(text: $0, at: operatorLabelPoint) })
    })

    /// The top of the terminal, where the agent's lines appear.
    static let terminalCamera = "camera:terminal"

    private static let linksLabel = Label(text: "Links from the session, collected for you", near: "context:links")

    private static let contextScene = Scene(id: "context", frames: [
        Frame(step: .context(0), hold: 1.0),
        Frame(step: .context(0), hold: 0.4, zoom: "context:todo"),
        Frame(
            step: .context(1), hold: 1.6, pointer: .hover(Spot(target: "context:todo")),
            label: Label(text: "The agent's to-do, live", near: "context:todo"), zoom: "context:todo"),
        Frame(
            step: .context(2), hold: 1.6, pointer: .hover(Spot(target: "context:pull-requests")),
            label: Label(text: "Its pull requests and CI", near: "context:pull-requests"),
            zoom: "context:pull-requests"),
        Frame(
            step: .context(3), hold: 2.0,
            label: Label(text: "The agent names an issue", at: CGPoint(x: 300, y: 380)), zoom: terminalCamera),
        Frame(step: .context(4), hold: 2.4, label: linksLabel, zoom: "context:links"),
        Frame(
            step: .context(4), hold: 1.8, pointer: .hover(Spot(target: "link:\(sentryURL)")), label: linksLabel,
            zoom: "context:links"),
        Frame(step: .context(4), hold: 1.6),
    ])

    private static let publishLabel = Label(text: "Publish a port as an https app", at: CGPoint(x: 300, y: 340))

    private static let publishScene = Scene(id: "publish", frames: [
        Frame(step: .publishedApps, hold: 2.4),
        Frame(step: .publishing, hold: 2.6, label: publishLabel),
        Frame(step: .published, hold: 3.2, pointer: .hover(Spot(target: "site:shop.acme.example.com")), label: publishLabel),
    ])

    private static let briefingCard = "scheduled:\(DemoScheduled.briefingID)"
    private static let newTaskLabel = Label(
        text: "A command, or a prompt for Claude or Codex", endingAt: CGPoint(x: 480, y: 300))

    private static let scheduledScene = Scene(id: "scheduled", frames: [
        Frame(
            step: .scheduledList, hold: 2.4,
            label: Label(text: "Tasks that run on their own, on a schedule", near: "scheduled:new")),
        Frame(
            step: .scheduledDetail, hold: 2.0, pointer: .click(Spot(target: briefingCard)),
            label: Label(text: "Every month, Claude writes the briefing", near: briefingCard, below: true)),
        Frame(
            step: .scheduledOutput, hold: 0.6,
            pointer: .click(Spot(target: "scheduled:run:\(DemoScheduled.briefingRun)"))),
        Frame(
            step: .scheduledOutput, hold: 2.8,
            label: Label(text: "Each run's output, kept", near: "scheduled:output"), zoom: "scheduled:output"),
        Frame(step: .scheduledNew, hold: 2.6, pointer: .click(Spot(target: "scheduled:new")), label: newTaskLabel),
        Frame(step: .scheduledNew, hold: 1.6, label: newTaskLabel),
    ])

    private static let shareLabel = Label(text: "Share a session with a link and a password", at: CGPoint(x: 572, y: 420))
    private static let browserLabel = Label(text: "They open it in a browser — no install", at: CGPoint(x: 545, y: 420))
    private static let chatLabel = Label(text: "You see what they type, and chat beside it", endingAt: CGPoint(x: 1140, y: 200))

    private static let shareScene = Scene(id: "share", frames: [
        Frame(step: .shareStart, hold: 1.6),
        Frame(step: .shareSheet, hold: 1.0, pointer: .click(Spot(target: acmeClaude), secondary: true), label: shareLabel),
        Frame(step: .shareSheet, hold: 0.8, pointer: .hover(Spot(target: "sheet:share-name")), label: shareLabel),
        Frame(step: .shareSheet, hold: 0.8, pointer: .hover(Spot(target: "sheet:share-for")), label: shareLabel),
        Frame(step: .shareSheet, hold: 1.0, pointer: .hover(Spot(target: "sheet:share-mode")), label: shareLabel),
        Frame(step: .shareLink, hold: 1.2, pointer: .click(Spot(target: "sheet:share")), label: browserLabel),
        Frame(step: .shareLink, hold: 1.0, pointer: .hover(Spot(target: "sheet:share-link")), label: browserLabel),
        Frame(step: .shareLink, hold: 1.2, pointer: .hover(Spot(target: "sheet:share-password")), label: browserLabel),
        Frame(step: .shared, hold: 1.0, pointer: .click(Spot(target: "sheet:done"))),
        Frame(step: .chat, hold: 1.0, pointer: .click(Spot(target: "tab:Chat")), label: chatLabel),
        Frame(step: .guestReply, hold: 1.6, label: chatLabel),
        Frame(step: .ownerReply, hold: 2.6, label: chatLabel),
    ])

    private static func carried(
        _ step: (Int) -> Step, count: Int, target: String, place: Spot.Place, label: String
    ) -> [Frame] {
        (0..<count).map { index in
            let spot = Spot(target: target, place: place)
            let pointer: Pointer = index == 0 ? .click(spot) : .follow(spot)
            let hold: Double = index == count - 1 ? 1.6 : 0.08
            let caption = Label(text: label, near: target, byCorner: place == .bottomTrailing)
            return Frame(step: step(index), hold: hold, pointer: pointer, label: caption)
        }
    }

    private static let homeScene: Scene = {
        let drag = carried(
            { .homeDrag($0) }, count: homeDragFrames, target: "widget:\(codexUsage)", place: .header,
            label: "Drag to arrange")
        let resize = carried(
            { .homeResize($0) }, count: homeResizeFrames, target: "widget:\(claudeUsage)", place: .bottomTrailing,
            label: "Resize")
        let add: [Frame] = [
            Frame(
                step: .homeGallery, hold: 2.2, pointer: .click(Spot(target: "home:add")),
                label: Label(text: "Add any widget", near: "sheet:gallery")),
            Frame(step: .homeAdded, hold: 2.8, pointer: .click(Spot(target: "sheet:gallery:\(summaryType)"))),
        ]
        return Scene(id: "home", frames: [Frame(step: .homeStart, hold: 1.8)] + drag + resize + add)
    }()

    /// One entry per state, so `DEVMACHINE_DEMO_WALK=site` is a walk like
    /// the others; `run` draws the pointer frames between them.
    static let screens: [DemoSnapshots.Screen] = scenes.flatMap { scene in
        scene.frames.indices.map { index in
            DemoSnapshots.Screen(
                id: "site-\(scene.id)-\(String(format: "%03d", index + 1))",
                fileName: "\(scene.id)/\(frameName(index))",
                settleNanoseconds: 350_000_000)
        }
    }

    static func handles(_ id: String) -> Bool { id.hasPrefix("site-") }

    /// `DEVMACHINE_DEMO_SCENES=context,home` renders only those scenes.
    static func scenes(environment: [String: String]) -> [Scene] {
        guard let raw = environment["DEVMACHINE_DEMO_SCENES"], !raw.isEmpty else { return scenes }
        let ids = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return scenes.filter { ids.contains($0.id) }
    }

    static func frameName(_ index: Int) -> String {
        String(format: "%03d.png", index + 1)
    }

    /// ffmpeg's concat list: each frame with its time on screen. The last
    /// frame is named once more, so it starts no earlier than its hold ends;
    /// the video script cuts the scene at the sum of the holds.
    static func ffconcat(_ holds: [Double]) -> String {
        var lines = ["ffconcat version 1.0"]
        for (index, hold) in holds.enumerated() {
            lines.append("file '\(frameName(index))'")
            lines.append("duration \(String(format: "%.3f", hold))")
        }
        if !holds.isEmpty {
            lines.append("file '\(frameName(holds.count - 1))'")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func reset(_ model: AppModel) {
        DemoData.transcriptOverride = [:]
        DemoData.walkLocalSessions = []
        DemoContextOverride.shared.value = nil
        SessionShareStore.shared.seedDemo([])
        model.contextCollapsed = false
        model.sidebarCollapsed = false
        model.contextWidth = DMPaneWidth.context.ideal
        var settings = SettingsStore.shared.settings ?? model.settings ?? .empty
        settings.showsHarnessIcons = true
        settings.harnessIconStyle = .color
        SettingsStore.shared.settings = settings
        model.settings = settings
    }

    /// With the Chat tab the panel has five tabs, and at its ideal width the
    /// first title wraps.
    static let chatPanelWidth: CGFloat = 340

    // MARK: - Running

    private struct Overlay {
        var image: NSBitmapImageRep
        var sheetOrigin = CGPoint.zero
    }

    static func run(window: NSWindow, environment: DemoSnapshots.Environment, directory: URL) async {
        environment.model.sidebarCollapsed = false
        DemoClickTargets.frames[terminalCamera] = CGRect(x: 280, y: 40, width: 500, height: 320)
        relayHome(environment.model)
        try? await Task.sleep(nanoseconds: 300_000_000)
        for scene in scenes(environment: ProcessInfo.processInfo.environment) {
            let folder = directory.appendingPathComponent(scene.id, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var holds: [Double] = []
            var pointer = restingPointer
            var last: Overlay?
            var scale: CGFloat = 2
            var camera: CGRect?
            let captureScale: CGFloat? = scene.frames.contains { $0.zoom != nil } ? DemoCamera.captureScale : nil

            func emit(_ rep: NSBitmapImageRep, hold: Double) {
                let url = folder.appendingPathComponent(frameName(holds.count))
                if let camera {
                    DemoSnapshots.writeFramed(
                        DemoCamera.crop(rep, to: camera, scale: scale), scale: scale, kind: .panel, to: url)
                } else {
                    DemoSnapshots.writeFramed(rep, scale: scale, to: url)
                }
                holds.append(hold)
            }

            for frame in scene.frames {
                if let before = last {
                    let target = frame.zoom.flatMap { DemoClickTargets.frames[$0] }.map(DemoCamera.rect(around:))
                    if target != camera {
                        let still = DemoPointer.draw(on: before.image, at: pointer, ring: nil, scale: scale)
                        for rect in DemoCamera.path(from: camera, to: target) {
                            camera = rect
                            emit(still, hold: DemoCamera.frameSeconds)
                        }
                        camera = target
                    }
                }
                if let action = frame.pointer, let before = last {
                    if let target = point(for: action.spot, sheet: before.sheetOrigin) {
                        switch action {
                        case .click, .hover:
                            for position in DemoPointer.path(from: pointer, to: target) {
                                emit(DemoPointer.draw(on: before.image, at: position, ring: nil, scale: scale),
                                     hold: DemoPointer.moveFrameSeconds)
                            }
                            if case .click = action {
                                for ring in DemoPointer.rings {
                                    emit(DemoPointer.draw(on: before.image, at: target, ring: ring, scale: scale),
                                         hold: DemoPointer.clickFrameSeconds)
                                }
                            }
                            pointer = target
                        case .follow:
                            break
                        }
                    } else {
                        FileHandle.standardError.write(Data("site walk: no target \(action.spot.target)\n".utf8))
                    }
                }
                await prepare(frame.step, environment: environment)
                try? await Task.sleep(nanoseconds: 350_000_000)
                TerminalRegistry.shared.replayDemoTranscripts()
                try? await Task.sleep(nanoseconds: 250_000_000)
                window.displayIfNeeded()
                guard let content = window.contentView,
                      let shot = DemoSnapshots.bitmap(of: content, scale: captureScale)
                else { continue }
                scale = CGFloat(shot.pixelsWide) / content.bounds.width
                var state = Overlay(image: DemoSnapshots.flattenTransparency(shot))
                if let sheet = sheet(for: frame.step, model: environment.model) {
                    let hosting = DemoSnapshots.standaloneView(sheet.view, fittingSize: NSSize(width: 480, height: 400))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if let sheetShot = DemoSnapshots.bitmap(of: hosting, scale: captureScale) {
                        let origin = sheet.below.flatMap { popoverOrigin(below: $0, width: hosting.bounds.width) }
                        let drawn = DemoSnapshots.drawSheet(sheetShot, over: state.image, scale: scale, origin: origin)
                        state = Overlay(image: drawn.image, sheetOrigin: drawn.origin)
                        DemoClickTargets.frames["sheet:gallery"] = CGRect(origin: .zero, size: hosting.bounds.size)
                    }
                    hosting.window?.orderOut(nil)
                }
                if case .follow = frame.pointer, let target = point(for: frame.pointer!.spot, sheet: state.sheetOrigin) {
                    pointer = target
                }
                last = state
                var image = state.image
                if let label = frame.label, let place = labelPlace(label, sheet: state.sheetOrigin) {
                    image = DemoPointer.drawLabel(label.text, on: image, place: place, scale: scale)
                }
                emit(DemoPointer.draw(on: image, at: pointer, ring: nil, scale: scale), hold: frame.hold)
            }
            try? Data(ffconcat(holds).utf8).write(to: folder.appendingPathComponent("frames.ffconcat"))
        }
    }

    private static func rect(for target: String, sheet origin: CGPoint) -> CGRect? {
        guard let frame = DemoClickTargets.frames[target] else { return nil }
        return target.hasPrefix("sheet:") ? frame.offsetBy(dx: origin.x, dy: origin.y) : frame
    }

    /// The spot on a control, in the main window's points from the top left.
    private static func point(for spot: Spot, sheet origin: CGPoint) -> CGPoint? {
        guard let frame = rect(for: spot.target, sheet: origin) else { return nil }
        switch spot.place {
        case .center: return CGPoint(x: frame.midX, y: frame.midY)
        case .header: return CGPoint(x: frame.minX + min(60, frame.width / 2), y: frame.minY + 18)
        case .bottomTrailing: return CGPoint(x: frame.maxX - 5, y: frame.maxY - 5)
        }
    }

    /// Beside its control, on the side with room; or where it was put.
    private static func labelPlace(_ label: Label, sheet origin: CGPoint) -> DemoPointer.LabelPlace? {
        if let at = label.at { return .leading(at) }
        if let end = label.endingAt { return .trailing(end) }
        guard let near = label.near, let frame = rect(for: near, sheet: origin) else { return nil }
        if label.byCorner { return .leading(CGPoint(x: frame.maxX + 14, y: frame.maxY - 14)) }
        if label.below { return .trailing(CGPoint(x: frame.maxX, y: frame.maxY + 26)) }
        return frame.minX > 420
            ? .trailing(CGPoint(x: frame.minX - 14, y: frame.minY + min(frame.height / 2, 24)))
            : .leading(CGPoint(x: frame.maxX + 14, y: frame.minY + min(frame.height / 2, 24)))
    }

    /// Where a popover opened from `anchor` sits: under it, kept inside the
    /// window.
    private static func popoverOrigin(below anchor: String, width: CGFloat) -> CGPoint? {
        guard let frame = DemoClickTargets.frames[anchor] else { return nil }
        let x = min(frame.midX - width / 2, windowSize.width - width - 12)
        return CGPoint(x: max(12, x), y: frame.maxY + 10)
    }

    // MARK: - Steps

    static func prepare(_ step: Step, environment: DemoSnapshots.Environment) async {
        let model = environment.model
        switch step {
        case .operatorChooser:
            guard model.activePage == nil || !isChooser(model.activePage) else { break }
            reset(model)
            model.sessionsByAlias = sessions(busy: true, attention: true)
            model.contextCollapsed = true
            model.goHome()
            var settings = SettingsStore.shared.settings ?? .empty
            settings.operatorProgram = nil
            SettingsStore.shared.settings = settings
            model.settings = settings
            model.clickLocalSession(DemoSnapshots.operatorSelection)
            try? await Task.sleep(nanoseconds: 400_000_000)
        case .operatorPick:
            DemoData.transcriptOverride = [operatorKind: operatorStart.joined(separator: "\n")]
            model.chooseOperatorProgram(.harness(.claude))
        case let .operatorChat(index):
            DemoData.transcriptOverride = [operatorKind: operatorPlayed[index].transcript]
        case .sidebar:
            reset(model)
            model.sessionsByAlias = sessions(busy: true, attention: true)
            model.contextCollapsed = true
            model.goHome()
            model.clickSession(contextSession)
        case .sessionGrid:
            model.sessionGridCellSizes = [:]
            model.openSessionGrid(acme)
        case .gridMove:
            model.moveSessionGridCell(SessionRef(alias: acme, name: gridCell), by: 1)
        case .gridHalf, .gridFull, .gridRestore:
            model.cycleSessionGridCellSize(SessionRef(alias: acme, name: gridCell))
        case let .cli(index):
            if index == 0 {
                reset(model)
                model.sessionsByAlias = sessions(busy: true, attention: true)
                DemoData.walkLocalSessions = [terminalSession]
                model.contextCollapsed = true
                model.goHome()
                model.selection = .localSession(name: terminalSession.handle, path: terminalSession.path)
            }
            DemoData.transcriptOverride = [terminalKind: cliPlayed[index].transcript]
        case let .context(index):
            DemoContextOverride.shared.value = contextStates[index]
            DemoData.transcriptOverride = [contextKind: contextTranscripts[index]]
            if index == 0 {
                reset(model)
                DemoContextOverride.shared.value = contextStates[index]
                DemoData.transcriptOverride = [contextKind: contextTranscripts[index]]
                model.sessionsByAlias = sessions(busy: true, attention: true)
                model.contextTab = .context
                model.goHome()
                model.clickSession(contextSession)
                // The panel opens on the session's last answer and reads again
                // a beat later; the walk waits for that read.
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            model.context.retry()
        case .publishedApps:
            reset(model)
            model.sessionsByAlias = sessions(busy: true, attention: true)
            model.contextTab = .context
            model.contextWidth = chatPanelWidth
            model.goHome()
            DemoSnapshots.subdomainsInitialTab = .sites
            model.showPage(.subdomains)
            try? await Task.sleep(nanoseconds: 400_000_000)
            showSites(environment.caddyStore, extra: nil)
        case .publishing:
            showSites(environment.caddyStore, extra: .pending)
        case .published:
            showSites(environment.caddyStore, extra: .published)
        case .scheduledList:
            reset(model)
            model.sessionsByAlias = sessions(busy: true, attention: true)
            model.contextCollapsed = true
            model.goHome()
            DemoScheduled.seed(ScheduledStore.shared)
            model.showPage(.scheduled)
            try? await Task.sleep(nanoseconds: 400_000_000)
        case .scheduledDetail:
            ScheduledStore.shared.selectedID = DemoScheduled.briefingID
        case .scheduledOutput:
            ScheduledStore.shared.openRunID = DemoScheduled.briefingRun
        case .scheduledNew:
            break
        case .shareStart:
            reset(model)
            model.sessionsByAlias = sessions(busy: true, attention: true)
            model.contextTab = .context
            model.contextWidth = chatPanelWidth
            model.goHome()
            model.clickSession(shareSession)
        case .shareSheet:
            break
        case .shareLink:
            SessionShareStore.shared.seedDemo([shareRecord])
        case .shared:
            break
        case .chat:
            model.contextTab = .chat
        case .guestReply:
            SessionChatStore.shared.receive(guestMessage, share: shareRecord.id)
        case .ownerReply:
            SessionChatStore.shared.receive(ownerMessage, share: shareRecord.id)
        case .homeStart:
            reset(model)
            model.sessionsByAlias = sessions(busy: true, attention: true)
            model.goHome()
            try? await Task.sleep(nanoseconds: 200_000_000)
            relayHome(model)
            try? await Task.sleep(nanoseconds: 300_000_000)
            homeStart = board()
            if let summary = homeStart.first(where: { $0.type == summaryType }) {
                HomeBoardController.shared.remove(summary.id)
            }
        case let .homeDrag(index):
            guard let from = widget(codexUsage, in: homeStart), let clock = homeStart.first(where: { $0.type == clockType })
            else { break }
            let to = BoardFrame(x: clock.frame.x, y: clock.frame.y + clock.frame.h + 24, w: from.frame.w, h: from.frame.h)
            let t = DemoPointer.easeInOut(Double(index + 1) / Double(homeDragFrames))
            HomeBoardController.shared.move(codexUsage, to: lerp(from.frame, to, t))
        case let .homeResize(index):
            guard let claude = widget(claudeUsage, in: homeStart), let codex = widget(codexUsage, in: homeStart)
            else { break }
            let wide = codex.frame.x + codex.frame.w - claude.frame.x
            let t = DemoPointer.easeInOut(Double(index + 1) / Double(homeResizeFrames))
            var frame = claude.frame
            frame.w = Int(Double(claude.frame.w) + Double(wide - claude.frame.w) * t)
            HomeBoardController.shared.resize(claudeUsage, to: frame, auto: claude.size == BoardWidget.autoSize, sizes: [])
        case .homeGallery:
            break
        case .homeAdded:
            let controller = HomeBoardController.shared
            if let summary = controller.catalog.catalog?.widgets.first(where: { $0.name == summaryType }) {
                _ = controller.add(summary, canvasWidth: controller.canvasWidth)
            }
        }
    }

    /// Home's board was written for the window the app opened with, before
    /// the walk sized it; written again for this window before the first
    /// scene, every scene that shows Home lays the cards out the way a person
    /// with this window first sees them.
    private static func relayHome(_ model: AppModel) {
        let controller = HomeBoardController.shared
        try? FileManager.default.removeItem(at: BoardStore.homeFileURL(configDirectory: DemoMode.boardsFolder))
        controller.canvasWidth = Int(windowSize.width - model.sidebarWidth - ResizeHandle.width)
        controller.reload()
    }

    // MARK: - Home

    static let summaryType = "devmachine-app/summary"
    private static let clockType = "devmachine-app/clock"
    private static var homeStart: [BoardWidget] = []

    /// The board ids Home's default layout gives the two usage cards.
    static let codexUsage = "codex-usage"
    static let claudeUsage = "claude-usage"

    private static func board() -> [BoardWidget] {
        HomeBoardController.shared.store?.board?.widgets ?? []
    }

    private static func widget(_ id: String, in widgets: [BoardWidget]) -> BoardWidget? {
        widgets.first { $0.id == id }
    }

    private static func lerp(_ from: BoardFrame, _ to: BoardFrame, _ t: Double) -> BoardFrame {
        func mix(_ a: Int, _ b: Int) -> Int { Int((Double(a) + Double(b - a) * t).rounded()) }
        return BoardFrame(x: mix(from.x, to.x), y: mix(from.y, to.y), w: mix(from.w, to.w), h: mix(from.h, to.h))
    }

    // MARK: - Sheets

    struct Sheet {
        let view: AnyView
        /// A popover opens under this control; a sheet, under the title bar.
        var below: String?
    }

    /// A sheet or popover drawn over the window for this state, where macOS
    /// shows it.
    static func sheet(for step: Step, model: AppModel) -> Sheet? {
        switch step {
        case .scheduledNew:
            return Sheet(view: AnyView(
                ScheduledTaskSheet(request: .new, draft: DemoScheduled.weeklyDraft) { _ in }
                    .environmentObject(model)))
        case .shareSheet:
            return Sheet(view: AnyView(ShareSessionSheet(
                request: SessionShareRequest(alias: acme, workspace: "acme", session: shareSession.name),
                onCancel: {}, onShare: { _, _, _ in })))
        case .shareLink:
            return Sheet(view: AnyView(ShareOutcomeSheet(
                outcome: .started(shareRecord, password: "otter-lamp-42"), onStop: { _ in }, onClose: {})))
        case .homeGallery:
            let controller = HomeBoardController.shared
            return Sheet(
                view: AnyView(WidgetGalleryPopover(
                    controller: controller, catalog: controller.catalog, canvasWidth: controller.canvasWidth,
                    onAdded: {}, onNewWidget: { _ in })
                    .background(Color.dmSidebarBg)),
                below: "home:add")
        default:
            return nil
        }
    }

    // MARK: - Sessions

    private static let acme = "acme-devmachine"

    private static let indicators: [String: SessionIndicators] = [
        "claude — payments refactor": SessionIndicators(branch: "fix/double-charge", ageSeconds: 7_400),
        "codex — landing page": SessionIndicators(branch: "feat/lazy-hero", ageSeconds: 2_600),
        "api — tests": SessionIndicators(branch: "main", ageSeconds: 11_000),
        "web — dev server": SessionIndicators(branch: "main", ageSeconds: 90_000),
        "dashboard — tests": SessionIndicators(branch: "main", ageSeconds: 18_000),
        "claude": SessionIndicators(branch: "feat/export-csv", ageSeconds: 1_500),
        "codex": SessionIndicators(branch: "chore/deps", ageSeconds: 180_000),
        "pi — docs": SessionIndicators(branch: "docs/setup", ageSeconds: 5_000),
        "agy — search": SessionIndicators(branch: "feat/search", ageSeconds: 30_000),
    ]

    /// umbrella keeps two sessions, so the sidebar fits the frame.
    static func sessions(busy: Bool, attention: Bool) -> [String: [TmuxSession]] {
        DemoData.sessionsByAlias.mapValues { list in
            list.prefix(list.count > 4 ? 2 : list.count).map { session in
                var marked = session
                var shown = indicators[session.name] ?? SessionIndicators(ageSeconds: 4_000)
                shown.busy = busy && session.name == "claude — payments refactor"
                shown.attention = attention && session.name == "codex — landing page"
                marked.indicators = shown
                return marked
            }
        }
    }

    // MARK: - Terminals

    static let operatorKind = TerminalKind.local(
        session: Workspace.operatorSession, path: DemoData.operatorPath)

    /// A plain shell on this Mac, for the scene where the commands are typed
    /// by hand.
    static let terminalSession = LocalSession(name: "terminal", path: "/Users/alice")
    static let terminalKind = TerminalKind.local(session: terminalSession.handle, path: terminalSession.path)

    private static let dim = "\u{1B}[2m"
    private static let bold = "\u{1B}[1m"
    private static let green = "\u{1B}[32m"
    private static let yellow = "\u{1B}[33m"
    private static let cyan = "\u{1B}[36m"
    private static let plain = "\u{1B}[0m"

    private static func command(_ text: String) -> String { "\(cyan)$\(plain) \(bold)\(text)\(plain)" }

    // MARK: - Typed scripts

    /// One beat of a terminal scene: a line typed at a reading pace, or
    /// lines printed one after another. The label shows for the whole beat.
    enum Beat {
        case type(prompt: String, text: String, label: String?)
        case print([String], label: String?)
    }

    struct Played: Equatable {
        let transcript: String
        let hold: Double
        let label: String?
    }

    static let typingChunk = 5
    static let typingSeconds = 0.34
    static let lineSeconds = 0.3
    static let settleSeconds = 1.0
    static let lastSeconds = 2.6

    /// Every frame of a typed script: a few characters at a time (about 15
    /// a second), each printed line 0.3 s after the one before, a second's
    /// pause after each beat, and a longer one on the last frame.
    static func play(_ beats: [Beat], start: [String]) -> [Played] {
        var lines = start
        var played: [Played] = []
        func show(_ shown: [String], _ hold: Double, _ label: String?) {
            played.append(Played(transcript: shown.joined(separator: "\n"), hold: hold, label: label))
        }
        for beat in beats {
            switch beat {
            case let .type(prompt, text, label):
                var typed = 0
                while typed < text.count {
                    typed = min(text.count, typed + typingChunk)
                    let done = typed == text.count
                    show(lines + [prompt + String(text.prefix(typed))], done ? settleSeconds : typingSeconds, label)
                }
                lines.append(prompt + text)
            case let .print(printed, label):
                let shownLines = printed.filter { !$0.isEmpty }
                var count = 0
                for line in printed {
                    lines.append(line)
                    guard !line.isEmpty else { continue }
                    count += 1
                    show(lines, count == shownLines.count ? settleSeconds : lineSeconds, label)
                }
            }
        }
        if let last = played.popLast() {
            played.append(Played(transcript: last.transcript, hold: lastSeconds, label: last.label))
        }
        return played
    }

    // MARK: - CLI

    private static let shell = "\(cyan)$\(plain) "
    private static let typeYourself = "Prefer a terminal? Type it yourself"

    /// `machines add`, `packages add` and `sync` typed by hand, with the
    /// CLI's own words and Ansible's output in between.
    static let cliBeats: [Beat] = [
        .type(prompt: shell, text: "devmachine machines add --name main --address 203.0.113.10", label: typeYourself),
        .print([
            "",
            "main at 203.0.113.10 presented ssh-ed25519 host key SHA256:Zm9yZXhhbXBsZW9ubHk.",
            "the key ~/.ssh/id_ed25519 already logs in as root@203.0.113.10, so no password is needed.",
            "turning password login off...",
            "password login is off; the key is the only way in.",
            "installing Ansible...",
            "",
            "added main to /Users/alice/.config/devmachine/config.yml",
            "",
        ], label: typeYourself),
        .type(prompt: shell, text: "devmachine packages add claude-code --workspace acme", label: nil),
        .print(["added claude-code to workspace acme", ""], label: nil),
        .type(prompt: shell, text: "devmachine sync --machine main", label: nil),
        .print([
            "",
            "TASK [workspace : Create the account] ******************************",
            "\(yellow)changed: [main]\(plain)",
            "",
            "TASK [claude-code : Install Claude Code] ***************************",
            "\(yellow)changed: [main]\(plain)",
            "",
            "PLAY RECAP *********************************************************",
            "main     : \(green)ok=86\(plain)  \(yellow)changed=12\(plain)  unreachable=0  failed=0",
            "",
            "main: ok=86 changed=12 failed=0",
        ], label: nil),
    ]

    static let cliPlayed = play(cliBeats, start: [])

    // MARK: - Operator

    private static let you = "\(bold)❯\(plain) "
    private static func ran(_ command: String) -> String { "\(green)⏺\(plain) Bash(\(command))" }
    private static func output(_ lines: [String]) -> [String] {
        lines.enumerated().map { index, line in (index == 0 ? "  ⎿  " : "     ") + "\(dim)\(line)\(plain)" }
    }
    private static func said(_ lines: [String]) -> [String] {
        lines.enumerated().map { index, line in (index == 0 ? "\(cyan)⏺\(plain) " : "  ") + line }
    }

    static let requests = [
        "Add a workspace for alice on main with docker",
        "Why is staging slow?",
    ]

    private static let askLabel = "Ask in plain words"
    private static let runsLabel = "The Operator runs devmachine for you"
    static let answerLabel = "and tells you what it found"

    /// Three requests, each typed, then the `devmachine` commands the
    /// Operator runs with the CLI's own output, then its answer.
    static let operatorBeats: [Beat] = [
        .type(prompt: you, text: requests[0], label: askLabel),
        .print(
            [""] + [ran("devmachine workspaces new alice --machine main --yes")]
                + output([
                    "alice is in the configuration, on main, with the packages claude-code.",
                    "The machine is untouched: `devmachine sync` is what creates the account.",
                ])
                + [ran("devmachine packages add docker --machine main")] + output(["added docker to machine main"])
                + [ran("devmachine sync --machine main")] + output(["main: ok=91 changed=14 failed=0"]),
            label: runsLabel),
        .print([""] + said(["alice is ready on main, with Docker. Open it with devmachine ssh alice."]) + [""], label: nil),
        .type(prompt: you, text: requests[1], label: nil),
        .print(
            [""] + [ran("devmachine stats --machine staging")]
                + output([
                    "machine staging (203.0.113.30)",
                    "cpus    2, load 3.84 3.51 2.97",
                    "memory  3.6G used of 3.8G, 210.0M available",
                    "swap    1.9G used of 2.0G",
                ]),
            label: nil),
        .print(
            [""] + said([
                "staging is short of memory and swap is almost full, so it pages to disk.",
                "More memory, or one app less, fixes it.",
            ]),
            label: answerLabel),
    ]

    static let operatorStart = ["\(bold)\(cyan)● Claude Code\(plain) — ~/.config/devmachine", ""]

    static let operatorPlayed = play(operatorBeats, start: operatorStart)

    private static func isChooser(_ page: AppPage?) -> Bool {
        if case .operatorChooser = page { return true }
        return false
    }

    // MARK: - Context

    static let contextSession = SessionRef(alias: "acme-devmachine", name: "claude — payments refactor")

    private static let planTexts = [
        "Reproduce the double-charge with a fake gateway",
        "Add an idempotency key to ChargeService",
        "Cover the timeout-then-retry path with a test",
        "Update CHANGELOG",
    ]

    private struct ContextStep {
        let done: Int
        let ci: String
        /// The agent has named the Sentry issue in the session.
        let printed: Bool
        /// The panel has read the session since then.
        let collected: Bool
    }

    private static let contextSteps: [ContextStep] = [
        ContextStep(done: 1, ci: "pending", printed: false, collected: false),
        ContextStep(done: 2, ci: "pending", printed: false, collected: false),
        ContextStep(done: 2, ci: "success", printed: false, collected: false),
        ContextStep(done: 2, ci: "success", printed: true, collected: false),
        ContextStep(done: 2, ci: "success", printed: true, collected: true),
    ]

    static let sentryURL = "https://acme.sentry.io/issues/4211/"

    static let contextStates: [ContextState] = contextSteps.map { step in
        let source = contextTranscript(step, printed: step.collected)
        return context(done: step.done, ci: step.ci, links: collectedLinks(source))
    }

    static let contextKind = TerminalKind.remote(alias: contextSession.alias, session: contextSession.name)

    private static let todoTexts = [
        "Reproduce with a fake gateway", "Add an idempotency key", "Cover the retry path in a test", "Update CHANGELOG",
    ]

    static let contextTranscripts: [String] = contextSteps.map { contextTranscript($0, printed: $0.printed) }

    /// The session's own screen keeps pace with the panel: the same to-do
    /// list, the pages the agent read, and the Sentry issue it names.
    private static func contextTranscript(_ step: ContextStep, printed: Bool) -> String {
        var lines = [
            "\(bold)\(cyan)● Claude Code\(plain) — payments refactor",
            "",
            "Read https://linear.app/acme/issue/PAY-212",
            "Read https://acme.example.com/docs/payments",
            "",
            "Found the retry loop that double-",
            "charges on a gateway timeout.",
            "",
            "\(bold)Todo\(plain)",
        ]
        for (index, text) in todoTexts.enumerated() {
            if index < step.done {
                lines.append("  \(green)✔\(plain) \(text)")
            } else if index == step.done {
                lines.append("  \(yellow)→\(plain) \(text)")
            } else {
                lines.append("  \(dim)○ \(text)\(plain)")
            }
        }
        if printed {
            lines += ["", "\(cyan)⏺\(plain) Sentry has the same timeout:", "  \(sentryURL)"]
        }
        lines += ["\(cyan)❯\(plain)"]
        return lines.joined(separator: "\n")
    }

    /// The links the app's own engine collects from that text: every URL,
    /// labelled and badged by `contextMapLinks`, in its order.
    static func collectedLinks(_ transcript: String) -> [ContextState.Link] {
        let plainText = transcript.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let refs = contextExtractRefs(
            blobs: [ContextRefBlob(text: plainText, timestamp: "")], defaultRepo: nil, githubHosts: ["github.com"])
        let links = refs.links
            .map { (url: $0.key, count: $0.value.count, lastTimestamp: $0.value.lastTimestamp) }
            .sorted { $0.url < $1.url }
        return contextMapLinks(links).map { ContextState.Link(url: $0.url, label: $0.label, kind: $0.kind) }
    }

    private static func context(done: Int, ci: String, links: [ContextState.Link]) -> ContextState {
        let items = planTexts.enumerated().map { index, text in
            ContextState.Plan.Item(
                text: text, state: index < done ? "done" : (index == done ? "active" : "pending"))
        }
        let base = DemoData.contextState
        let prs = base.prs.map { pr in
            pr.number == 415
                ? ContextState.PR(
                    number: pr.number, repo: pr.repo, title: pr.title, url: pr.url, ci: ci,
                    review: ci == "success" ? "approved" : pr.review, state: ci == "success" ? "open" : pr.state,
                    threads: pr.threads, lastSeen: pr.lastSeen)
                : pr
        }
        return ContextState(
            cwd: base.cwd, isClaude: true, updatedAt: base.updatedAt,
            plan: ContextState.Plan(
                title: "Fix double-charge on gateway timeout", source: "session",
                done: min(done, items.count), total: items.count, items: items),
            prs: prs, links: links)
    }

    // MARK: - Publish and share

    private static let shopRow = { (status: ExposedSite.Status) in
        SubdomainRow(
            site: ExposedSite(host: "shop.acme.example.com", port: 5173, workspace: "acme", status: status),
            resolvedWorkspace: "acme", containerName: status == .published ? "shop" : nil)
    }

    private static func showSites(_ caddy: CaddyStore, extra: ExposedSite.Status?) {
        var states = DemoData.subdomainStates
        if let extra {
            states["main"] = MachineSitesState(rows: DemoData.subdomainRows + [shopRow(extra)], hasLoaded: true)
        }
        caddy.show(
            machines: DemoData.subdomainMachines, states: states, selected: DemoData.subdomainSelectedMachine)
    }

    static let shareSession = SessionRef(alias: "acme-devmachine", name: "claude — payments refactor")

    static let shareRecord = SessionShareRecord(
        id: "wvx3januvgyj", workspace: "acme", alias: "acme-devmachine", session: shareSession.name,
        name: shareSession.name, mode: .read, url: "https://share-acme.example.com/s/wvx3januvgyj/",
        createdAt: Date(), expiresAt: Date().addingTimeInterval(3_600))

    private static let guestMessage = SessionChatMessage(
        id: "site-1", ts: Date(), from: "bob", role: "guest",
        text: "Joined. Is the retry test the one that fails?")

    private static let ownerMessage = SessionChatMessage(
        id: "site-2", ts: Date().addingTimeInterval(20), from: "alice", role: "owner",
        text: "Yes. Watch: I'm running it now.")
}
#endif
