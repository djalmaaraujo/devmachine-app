import AppKit
import Foundation
import SwiftTerm
import DevmachineCore

/// One live terminal (and one mosh/tmux client) per session for the whole app.
/// SwiftUI containers come and go — single pane, session grid — and re-attach
/// the same view, so switching layouts never reconnects.
@MainActor
final class TerminalRegistry: NSObject {
    static let shared = TerminalRegistry()
    /// How many detached terminals (and their clients) to keep around. Settable,
    /// because the right number is one per workspace plus the local ones: at
    /// six, moving between workspaces closed clients behind you, and coming
    /// back showed `[mosh is exiting.]` instead of the session.
    static var detachedLimit: Int {
        Appearance.clampKeptTerminals(
            SettingsStore.shared.settings?.keptTerminals ?? Appearance.defaultKeptTerminals)
    }

    private var terminals: [TerminalKind: LocalProcessTerminalView] = [:]
    private var optionKeyMonitor: Any?
    private var detachedAt: [TerminalKind: Date] = [:]
    /// Terminals whose process ended on its own — a dropped connection, a shell
    /// that exited. The view is kept so returning to it reconnects in place.
    private var dead: Set<TerminalKind> = []
    /// Views built but not started yet. A process must not begin while the view
    /// still has its placeholder size: whatever runs inside draws the screen for
    /// the size it is told at startup, and a program that repaints only on its
    /// own schedule never corrects it.
    private var awaitingSize: Set<TerminalKind> = []
    /// Panes that were put away and are now back on screen.
    private var reattached: Set<TerminalKind> = []
    private(set) var pendingFocusKind: TerminalKind?
    /// The connection being set up for each remote pane. A late answer from
    /// an attempt that is no longer this one is dropped.
    private var remoteLaunches: [TerminalKind: RemoteLaunch] = [:]
    private var warmHosts: [TerminalKind: NSWindow] = [:]
    private var warmSettled: [TerminalKind: PendingWarm] = [:]
    nonisolated static let resolveSupport = ResolveSupport()

    private struct RemoteLaunch {
        enum Next {
            case ssh(reason: MoshFallbackReason, detail: String)
            case restart
        }

        let id: UUID
        let alias: String
        let session: String
        var machine: String
        /// mosh-client runs and has five seconds to hear from the server.
        var probing = false
        var strayServerPID: Int?
        /// What to start once the process being stopped has exited.
        var next: Next?
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TerminalRegistry.shared.closeAll() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TerminalRegistry.shared.leaveIdleCopyModeOnScreen() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TerminalRegistry.shared.leaveIdleCopyModeOnScreen() }
        }
        installOptionKeyMonitor()
    }

    /// Option composes accents on this Mac (U.S. layout: ⌥c is ç, ⌥e a is á), so
    /// the terminals run with `optionAsMetaKey = false`. Arrows and other function
    /// keys still need Meta, or the shell loses word jumps — flip the flag for the
    /// length of those events only.
    private func installOptionKeyMonitor() {
        optionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated { () -> Bool in
                let registry = TerminalRegistry.shared
                // SwiftTerm's `keyDown` is not open, so Shift+Enter is answered
                // here: the focused terminal gets the newline byte and the event
                // stops, or the legacy encoding would send a plain Return.
                if TerminalKeyboard.sendsNewline(keyCode: keyCode, flags: flags),
                   let focused = registry.focusedTerminal() {
                    focused.send(TerminalKeyboard.newlineBytes)
                    return true
                }
                // A page key is answered by the terminal itself, which scrolls
                // its own buffer. That is right for a session running here, and
                // wrong for one inside tmux: the buffer holds a single screen,
                // so nothing moves and the host never sees the key.
                if let bytes = TerminalKeyboard.pageKeyBytes(keyCode: keyCode, flags: flags),
                   let (kind, view) = registry.focusedEntry(),
                   case .remote = kind {
                    view.send(bytes)
                    return true
                }
                // An image on the clipboard cannot be typed into a terminal,
                // and the agent reads the clipboard of the machine it runs on,
                // which for a remote session is not this Mac. So the bytes are
                // written over there and the path is typed instead.
                // The terminal answers ⌘F itself by doing nothing, and the
                // pane has no other way to reach SwiftTerm's search.
                if TerminalKeyboard.opensFind(keyCode: keyCode, flags: flags),
                   let (kind, _) = registry.focusedEntry() {
                    AppModel.shared?.findTarget = kind
                    return true
                }
                if TerminalKeyboard.pastesClipboard(keyCode: keyCode, flags: flags),
                   let (kind, _) = registry.focusedEntry(),
                   let image = FileUploadService.pastedImage(from: .general) {
                    PaneUploadStore.shared.receive(image, on: kind)
                    return true
                }
                guard TerminalKeyboard.optionActsAsMeta(for: flags) else { return false }
                for term in registry.terminals.values where term.window?.firstResponder === term {
                    term.optionAsMetaKey = true
                    DispatchQueue.main.async { term.optionAsMetaKey = false }
                }
                return false
            }
            return handled ? nil : event
        }
    }

    /// ⌘-click opens the link, ⌘⇧-click copies it. A link that names no page
    /// and no file on this Mac is dropped, and the log says which one: what a
    /// terminal prints is text from elsewhere, not a command for this Mac.
    func openLink(_ link: String, from kind: TerminalKind?, flags: NSEvent.ModifierFlags) {
        var folder: String?
        if case let .local(_, path) = kind { folder = path }
        guard let target = TerminalLink.target(for: link, folder: folder) else {
            PaneLog.log("dropped link \(link)")
            return
        }
        guard !flags.contains(.shift) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(target.text, forType: .string)
            return
        }
        switch target {
        case let .web(url): NSWorkspace.shared.open(url)
        case let .file(path): NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Searches the pane's own scrollback and selects the match.
    @discardableResult
    func find(_ term: String, in kind: TerminalKind, forward: Bool) -> Bool {
        let clean = term.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let view = terminals[kind] else { return false }
        return forward ? view.findNext(clean) : view.findPrevious(clean)
    }

    /// How many times `term` appears in the pane's own scrollback, without
    /// selecting or scrolling — the Add machine wizard polls this for its
    /// step markers instead of using `find`, which would move the person's
    /// view every time it checks.
    func matchCount(_ term: String, in kind: TerminalKind) -> Int {
        guard let view = terminals[kind] else { return 0 }
        return view.searchMatchSummary(term).total
    }

    /// The pane is mounted and its process started, so typed text reaches it.
    func isStarted(_ kind: TerminalKind) -> Bool {
        terminals[kind] != nil && !awaitingSize.contains(kind)
    }

    /// Drops the highlight and gives the keyboard back to the session.
    func endFind(in kind: TerminalKind) {
        terminals[kind]?.clearSearch()
        requestFocus(kind)
    }

    /// The terminal that currently owns the keyboard, if any.
    private func focusedTerminal() -> LocalProcessTerminalView? {
        focusedEntry()?.view
    }

    private func focusedEntry() -> (kind: TerminalKind, view: LocalProcessTerminalView)? {
        for (kind, view) in terminals where view.window?.firstResponder === view {
            return (kind, view)
        }
        return nil
    }

    /// Types uploaded paths without a newline: the sentence around them is
    /// yours to write.
    func type(_ text: String, into kind: TerminalKind) {
        terminals[kind]?.send(txt: text)
    }

    static func sendingLabel(for kind: TerminalKind, names: [String]) -> String {
        let what = names.count == 1 ? names[0] : "\(names.count) files"
        switch kind {
        case let .remote(alias, _): return "Sending \(what) to \(alias)\u{2026}"
        case .local: return "Saving \(what)\u{2026}"
        }
    }

    static func dropHint(for kind: TerminalKind) -> String {
        switch kind {
        case let .remote(alias, session): return "Drop files to upload to \(alias) / \(session)"
        case let .local(session, _): return "Drop files to upload to this Mac / \(session)"
        }
    }

    func terminal(for kind: TerminalKind) -> LocalProcessTerminalView {
        detachedAt[kind] = nil
        if let live = terminals[kind] {
            releaseWarmHost(kind)
            reviveIfDead(kind, view: live)
            return live
        }
        let term = makeTerminal(kind)
        awaitingSize.insert(kind)
        terminals[kind] = term
        return term
    }

    private func makeTerminal(_ kind: TerminalKind) -> LegacyKeyboardTerminalView {
        let term = LegacyKeyboardTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        term.processDelegate = self
        term.optionAsMetaKey = false
        term.kind = kind
        term.copiesOnSelect = { SettingsStore.shared.settings?.copyOnSelect ?? true }
        // ⌘ and a click, the way every other Mac terminal opens a link. A plain
        // click stays what it is, so clicking a web address inside a program
        // that reads the mouse still reaches the program.
        term.linkHighlightMode = .hoverWithModifier
        // Explicit hyperlinks plus bare addresses: the local multiplexer loses
        // the hyperlink when it repaints its screen, and the text is all that
        // is left to match.
        term.linkReporting = .implicit
        term.setAccessibilityHelp(Self.dropHint(for: kind))
        term.setProcessOutputHandler(Self.activityHandler(kind))
        return term
    }

    /// Records each chunk of a remote terminal's output in `TerminalActivity`.
    private static func activityHandler(_ kind: TerminalKind) -> (@Sendable () -> Void)? {
        guard case let .remote(alias, _) = kind else { return nil }
        return { TerminalActivity.shared.record(alias: alias) }
    }

    func autoConnectState() -> (open: Set<AutoConnectTarget>, room: Int) {
        let open = Set(terminals.keys.compactMap { kind -> AutoConnectTarget? in
            guard case let .remote(alias, session) = kind else { return nil }
            return AutoConnectTarget(alias: alias, session: session)
        })
        return (open, Self.detachedLimit - terminals.count)
    }

    func warm(_ kind: TerminalKind, settled: @escaping (Bool) -> Void) {
        guard !DemoMode.isActive, terminals[kind] == nil, case .remote = kind else {
            settled(false)
            return
        }
        let term = makeTerminal(kind)
        let host = Self.offScreenWindow()
        guard let content = host.contentView else {
            settled(false)
            return
        }
        content.addSubview(term)
        TerminalPaneView.applyAppearance(to: term, container: content, translucent: false)
        let size = Self.lastPaneSize() ?? Self.defaultPaneSize(of: term)
        host.setContentSize(size)
        term.frame = NSRect(origin: .zero, size: size)
        terminals[kind] = term
        warmHosts[kind] = host
        warmSettled[kind] = PendingWarm(settled: settled, since: Date())
        let view = ObjectIdentifier(term)
        let activity = Self.activityHandler(kind)
        term.setProcessOutputHandler {
            activity?()
            Task { @MainActor in TerminalRegistry.shared.processDidSpeak(kind, view: view) }
        }
        reattached.insert(kind)
        detachedAt[kind] = Date()
        PaneLog.log("warm pane=\(kind) frame=\(Int(size.width))x\(Int(size.height))")
        start(kind, in: term)
    }

    // The terminal must start at its real size: a program draws for the size
    // it is told at startup, so a warm terminal needs a window of that size.
    static func offScreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return window
    }

    private func releaseWarmHost(_ kind: TerminalKind) {
        guard let host = warmHosts.removeValue(forKey: kind) else { return }
        terminals[kind]?.removeFromSuperview()
        host.close()
    }

    private func settleWarm(_ kind: TerminalKind, running: Bool, via cause: WarmSettleCause) {
        guard let pending = warmSettled.removeValue(forKey: kind) else { return }
        terminals[kind]?.setProcessOutputHandler(Self.activityHandler(kind))
        PaneLog.log(Self.warmSettledLine(
            kind, running: running, after: Date().timeIntervalSince(pending.since), via: cause))
        pending.settled(running)
    }

    static func warmSettledLine(
        _ kind: TerminalKind, running: Bool, after: TimeInterval, via cause: WarmSettleCause
    ) -> String {
        "warm \(running ? "running" : "failed") pane=\(kind) after=\(Int((after * 1000).rounded()))ms "
            + "via=\(cause.rawValue)"
    }

    /// The first bytes from the program. SwiftTerm hands a process's output
    /// to the view's own parser, never to `dataReceived(slice:)`, so the
    /// output handler is the only place they can be seen.
    func processDidSpeak(_ kind: TerminalKind, view: ObjectIdentifier) {
        guard let term = terminals[kind], ObjectIdentifier(term) == view else { return }
        settleWarm(kind, running: true, via: .bytes)
    }

    /// The auto-connect queue gave up waiting; a later answer changes nothing.
    func warmTimedOut(_ kind: TerminalKind) {
        settleWarm(kind, running: false, via: .timeout)
        // A connect that never answered would be reused, still "Connecting…",
        // when the session is opened; closing it makes that open start fresh.
        if warmHosts[kind] != nil { close(kind) }
    }

    private static let lastPaneSizeKey = "lastTerminalPaneSize"

    private static func lastPaneSize() -> NSSize? {
        guard let text = UserDefaults.standard.string(forKey: lastPaneSizeKey) else { return nil }
        let size = NSSizeFromString(text)
        return size.width > 0 && size.height > 0 ? size : nil
    }

    private static func rememberPaneSize(of term: LocalProcessTerminalView) {
        let grid = term.getWindowSize()
        guard TerminalSizeGuard.isUsable(cols: Int(grid.ws_col), rows: Int(grid.ws_row)) else { return }
        UserDefaults.standard.set(NSStringFromSize(term.frame.size), forKey: lastPaneSizeKey)
    }

    static func defaultPaneSize(of term: LocalProcessTerminalView) -> NSSize {
        let grid = term.getWindowSize()
        let optimal = term.getOptimalFrameSize()
        guard grid.ws_col > 0, grid.ws_row > 0 else { return NSSize(width: 1000, height: 640) }
        return NSSize(
            width: optimal.width / CGFloat(grid.ws_col) * 120,
            height: optimal.height / CGFloat(grid.ws_row) * 36)
    }

    /// No SwiftUI pane shows this terminal any more. It keeps running, and the
    /// longest-detached ones are closed once too many pile up — tmux holds the
    /// session server-side, so opening it again reconnects.
    func detach(_ kind: TerminalKind) {
        guard terminals[kind] != nil else { return }
        PaneLog.log("detach pane=\(kind)")
        reattached.insert(kind)
        detachedAt[kind] = Date()
        for stale in LRUEviction.keysToEvict(detachedAt: detachedAt, cap: Self.detachedLimit) {
            close(stale)
        }
    }

    /// Give the keyboard to this session as soon as its view is on screen. The
    /// request comes from an explicit user action (opening a session); mounting
    /// alone must never grab focus, or SwiftUI loses the sidebar's clicks.
    func requestFocus(_ kind: TerminalKind) {
        pendingFocusKind = kind
        applyPendingFocus()
    }

    /// A pane just put the shared view back in a window.
    func viewDidAttach(_ kind: TerminalKind) {
        if let view = terminals[kind] {
            reviveIfDead(kind, view: view)
            view.requestRedraw()
        }
        guard pendingFocusKind == kind else { return }
        // Next runloop: SwiftUI is still mid-layout, and taking first responder
        // inside it is what used to make the sidebar unclickable.
        DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
    }

    private func applyPendingFocus() {
        guard let kind = pendingFocusKind,
              let term = terminals[kind],
              let window = term.window
        else { return }
        pendingFocusKind = nil
        // A sheet (rename, new session, setup) owns the keyboard while it is up.
        guard window.isKeyWindow else { return }
        window.makeFirstResponder(term)
    }

    /// Called by the pane once the view has the size it will be drawn at. This
    /// is when a process may begin: it then learns the real number of rows and
    /// columns from its first breath.
    func viewDidSize(_ kind: TerminalKind) {
        if let term = terminals[kind], warmHosts[kind] == nil { Self.rememberPaneSize(of: term) }
        if awaitingSize.remove(kind) != nil, let term = terminals[kind] {
            start(kind, in: term)
            return
        }
        redrawAfterReattach(kind)
    }

    /// A pane that comes back at the size it left gets no size change, so the
    /// program inside is never told to draw again and the screen stays as it
    /// was left, which can be nearly empty. Each multiplexer is asked to repaint
    /// in its own way.
    /// Asks the program in a pane to draw its screen again, for a pane that is
    /// back on screen without anything having changed.
    func requestRepaint(_ kind: TerminalKind) {
        guard terminals[kind] != nil else { return }
        reattached.insert(kind)
        redrawAfterReattach(kind)
    }

    /// Whether a local pane's shell is back at its prompt: the Add machine
    /// wizard's terminal steps end on a marker, and this tells a step that
    /// died without one from a step still running. Nil when it cannot tell.
    func isAtPrompt(_ kind: TerminalKind) async -> Bool? {
        guard !DemoMode.isActive, case let .local(session, _) = kind, let term = terminals[kind] else { return nil }
        let directShell = term.process.shellPid
        let zmx = LocalTools.zmxPath()
        return await Task.detached { () -> Bool? in
            let runner = ProcessRunner()
            var shell = Int(directShell)
            if let zmx {
                let socketDirectory = Zmx.socketDirectory()
                let name = Zmx.sessionName(from: session, socketDirectory: socketDirectory)
                guard let listing = try? runner.run(
                    executable: zmx, args: Zmx.listArguments, environment: ["ZMX_DIR": socketDirectory]),
                    let pid = Zmx.pid(of: name, in: listing) else { return nil }
                shell = pid
            }
            guard shell > 0, let output = try? runner.run(
                executable: "/bin/ps", args: ProcessTree.tpgidArguments(pid: shell), environment: nil)
            else { return nil }
            return ProcessTree.isAtPrompt(shellPID: shell, tpgidOutput: output)
        }.value
    }

    /// Replaces ssh for a command sent to a session's host; tests record here.
    var hostCommandRunner: ((_ alias: String, _ command: String) -> Void)?
    private var checkingCopyMode = false
    var copyModeSchedule = CopyModeCheckSchedule()

    /// What the copy mode check asks of the rest of the app; tests stand in.
    struct CopyModeContext {
        var isPaused: (String) -> Bool
        var isSweeping: () -> Bool
        var machine: (String) -> String?
        var now: () -> Date
        /// An ssh-level failure pauses that workspace like the sweep's own.
        var report: (String, SSHFailure) -> Void
        /// Runs one check over ssh and says how it failed, if it did.
        var run: @Sendable (_ alias: String, _ command: String) -> SSHFailure?

        @MainActor static var live: CopyModeContext {
            let customSocket = SettingsStore.shared.settings?.sshAgentSocket
            return CopyModeContext(
                isPaused: { AppModel.shared?.isPollingPaused(alias: $0) ?? false },
                isSweeping: { AppModel.shared?.isSweeping ?? false },
                machine: { AppModel.shared?.machine(forAlias: $0) },
                now: { Date() },
                report: { AppModel.shared?.noteSSHFailure(alias: $0, $1) },
                run: { alias, command in
                    TerminalRegistry.runCheckOverSSH(alias: alias, command: command, customSocket: customSocket)
                })
        }
    }

    var copyModeContext: CopyModeContext?

    /// Coming back to the app leaves the panes on screen as they were, so a
    /// stray wheel-up that put one into tmux's copy mode while you were away
    /// would keep eating your keys. Each account with a pane on screen needs
    /// its own login (tmux runs a server per account), so how often is what
    /// is limited (`CopyModeCheckSchedule`): one ssh at a time, at most once
    /// per machine every 5 minutes, never for a paused workspace or while the
    /// sweep runs. A refused login pauses that workspace and an unreachable
    /// machine ends its own checks, both like the sweep's own.
    func leaveIdleCopyModeOnScreen() {
        guard !DemoMode.isActive, !checkingCopyMode else { return }
        let context = copyModeContext ?? .live
        var panes: [(alias: String, session: String)] = []
        for (kind, view) in terminals where view.window != nil && warmHosts[kind] == nil && !dead.contains(kind) {
            guard case let .remote(alias, session) = kind else { continue }
            panes.append((alias, session))
        }
        guard !panes.isEmpty else { return }
        let checks = copyModeSchedule.due(
            panes: panes, machine: context.machine, now: context.now(),
            isPaused: context.isPaused, sweeping: context.isSweeping())
        guard !checks.isEmpty else { return }
        PaneLog.log("copy mode check aliases=\(checks.map(\.alias))")
        checkingCopyMode = true
        let run = context.run
        let report = context.report
        Task { @MainActor in
            let failures = await Task.detached { () -> [(alias: String, failure: SSHFailure)] in
                var skipped: Set<String> = []
                var failures: [(alias: String, failure: SSHFailure)] = []
                for check in checks where !skipped.contains(check.machine) {
                    switch run(check.alias, check.command) {
                    case nil:
                        continue
                    case .hostKeyRejected?, .loginWaiting?:
                        skipped.insert(check.machine)
                    case .authDenied?:
                        failures.append((check.alias, .authDenied))
                    case .unreachable?:
                        skipped.insert(check.machine)
                        failures.append((check.alias, .unreachable))
                    }
                }
                return failures
            }.value
            for entry in failures { report(entry.alias, entry.failure) }
            checkingCopyMode = false
        }
    }

    nonisolated static func runCheckOverSSH(alias: String, command: String, customSocket: String?) -> SSHFailure? {
        guard let result = try? ProcessRunner().runCapturing(
            executable: "/usr/bin/ssh",
            args: RemoteCommands.sshBaseArgs(alias: alias) + [command],
            environment: RemoteCommands.sshEnvironment(customSocket: customSocket))
        else { return nil }
        return SSHFailure.classify(exitCode: result.exitCode, stderr: result.stderr)
    }

    private func runOnHost(alias: String, command: String) {
        if let hostCommandRunner {
            hostCommandRunner(alias, command)
            return
        }
        let customSocket = SettingsStore.shared.settings?.sshAgentSocket
        Task.detached {
            Self.runOverSSH(alias: alias, command: command, customSocket: customSocket)
        }
    }

    nonisolated private static func runOverSSH(alias: String, command: String, customSocket: String?) {
        _ = try? ProcessRunner().run(
            executable: "/usr/bin/ssh",
            args: RemoteCommands.sshBaseArgs(alias: alias) + [command],
            environment: RemoteCommands.sshEnvironment(customSocket: customSocket))
    }

    /// A demo pane has no program behind it to repaint after a resize or a
    /// move between layouts, so its transcript, which starts by clearing the
    /// screen, is drawn again from the top.
    func replayDemoTranscripts() {
        guard DemoMode.isActive else { return }
        for (kind, term) in terminals {
            term.feed(text: DemoData.terminalTranscript(for: kind))
            // SwiftTerm paints from a snapshot that only its frame clock
            // refreshes; a same-size frame refreshes it now, so a bitmap
            // capture taken next does not paint an old, empty frame.
            term.setFrameSize(term.frame.size)
            term.needsDisplay = true
        }
    }

    private func redrawAfterReattach(_ kind: TerminalKind) {
        terminals[kind]?.requestRedraw()
        guard reattached.remove(kind) != nil else { return }
        if DemoMode.isActive {
            terminals[kind]?.feed(text: DemoData.terminalTranscript(for: kind))
            return
        }
        switch kind {
        case let .remote(alias, session):
            PaneLog.log("refresh pane=\(kind)")
            runOnHost(alias: alias, command: RemoteCommands.returnToSession(session: session))
        case let .local(session, _):
            // No refresh command in the local multiplexer, so the program is
            // asked directly with the window-changed signal — the same one a
            // resize sends. Nothing is killed and no size changes.
            guard let zmx = LocalTools.zmxPath() else { return }
            PaneLog.log("repaint pane=\(kind)")
            let socketDirectory = Zmx.socketDirectory()
            let name = Zmx.sessionName(from: session, socketDirectory: socketDirectory)
            Task.detached {
                let runner = ProcessRunner()
                guard let listing = try? runner.run(
                    executable: zmx, args: Zmx.listArguments,
                    environment: ["ZMX_DIR": socketDirectory]),
                    let pid = Zmx.pid(of: name, in: listing),
                    let tpgid = try? runner.run(
                        executable: "/bin/ps", args: ProcessTree.tpgidArguments(pid: pid),
                        environment: nil),
                    let group = ProcessTree.foregroundGroup(fromTPGID: tpgid)
                else { return }
                _ = try? runner.run(
                    executable: "/bin/kill",
                    args: ProcessTree.windowChangedArguments(group: group),
                    environment: nil)
            }
        }
    }

    /// Starts the process again in the same view, so the pane you return to
    /// shows the session instead of the message its client left behind.
    private func reviveIfDead(_ kind: TerminalKind, view: LocalProcessTerminalView) {
        guard dead.contains(kind) else { return }
        PaneLog.log("revive pane=\(kind)")
        dead.remove(kind)
        start(kind, in: view)
    }

    /// Told when a session ends for good, so the app can drop its row and let
    /// the layout close over the gap.
    var onSessionEnded: ((TerminalKind) -> Void)?

    func close(_ kind: TerminalKind) {
        PaneLog.log("close pane=\(kind)")
        dead.remove(kind)
        awaitingSize.remove(kind)
        reattached.remove(kind)
        detachedAt[kind] = nil
        remoteLaunches[kind] = nil
        RemoteTransportStore.shared.forget(kind)
        if pendingFocusKind == kind { pendingFocusKind = nil }
        settleWarm(kind, running: false, via: .closed)
        guard let term = terminals.removeValue(forKey: kind) else { return }
        term.terminate()
        term.removeFromSuperview()
        warmHosts.removeValue(forKey: kind)?.close()
    }

    func close(alias: String, session: String) {
        close(.remote(alias: alias, session: session))
    }

    /// Ends the multiplexer session behind a local pane, so removing a session
    /// from the sidebar removes the shell too.
    func killLocalSession(named name: String) {
        guard !DemoMode.isActive else { return }
        guard let zmx = LocalTools.zmxPath() else { return }
        let socketDirectory = Zmx.socketDirectory()
        let session = Zmx.sessionName(from: name, socketDirectory: socketDirectory)
        Task.detached {
            _ = try? ProcessRunner().run(
                executable: zmx,
                args: Zmx.killArguments(name: session),
                environment: ["ZMX_DIR": socketDirectory]
            )
        }
    }

    /// Every pane of one workspace, closed together: hiding a workspace should
    /// end the connections it holds, not only stop drawing them.
    func closeWorkspace(alias: String) {
        for kind in Array(terminals.keys) {
            if case let .remote(paneAlias, _) = kind, paneAlias == alias { close(kind) }
        }
    }

    /// The app is quitting: no background connection may start another.
    func closeAll() {
        warmSettled.removeAll()
        for kind in Array(terminals.keys) { close(kind) }
    }

    private func start(_ kind: TerminalKind, in term: LocalProcessTerminalView) {
        if DemoMode.isActive {
            term.feed(text: DemoData.terminalTranscript(for: kind))
            return
        }
        PaneLog.log("start pane=\(kind)")
        let customSocket = SettingsStore.shared.settings?.sshAgentSocket
        switch kind {
        case let .remote(alias, session):
            startRemote(kind, alias: alias, session: session, in: term, customSocket: customSocket)
        case let .local(session, path):
            // The multiplexer holds the shell, so the session survives the app.
            // Without it the pane is still usable, just not persistent.
            let shell = LocalTools.shellLaunch()
            guard let zmx = LocalTools.zmxPath() else {
                term.startProcess(
                    executable: shell.executable,
                    args: shell.arguments,
                    environment: RemoteCommands.terminalEnvironment(customSocket: customSocket) + shell.environment,
                    execName: shell.execName,
                    currentDirectory: path
                )
                return
            }
            let socketDirectory = Zmx.socketDirectory()
            term.startProcess(
                executable: zmx,
                args: Zmx.attachArguments(
                    name: Zmx.sessionName(from: session, socketDirectory: socketDirectory),
                    command: shell.multiplexerCommand),
                environment: Zmx.environment(socketDirectory: socketDirectory) + shell.environment,
                // The session's own directory comes from here: the multiplexer
                // starts the shell in the directory it was launched from.
                currentDirectory: path
            )
        }
    }
}

// MARK: - Remote transport

extension TerminalRegistry {
    /// mosh when it gets through, ssh otherwise. The pane never waits on a
    /// path that cannot work: a machine without mosh-server goes to ssh at
    /// once, and a mosh-client that hears nothing for five seconds is
    /// replaced by ssh in the same view.
    private func startRemote(
        _ kind: TerminalKind, alias: String, session: String,
        in term: LocalProcessTerminalView, customSocket: String?
    ) {
        let settings = SettingsStore.shared.settings
        let mode = settings?.remoteTerminalMode ?? .automatic
        let client = MoshClientLocator.path(
            bundled: LocalTools.moshClientPath(),
            exists: { FileManager.default.isExecutableFile(atPath: $0) })
        let id = UUID()
        remoteLaunches[kind] = RemoteLaunch(id: id, alias: alias, session: session, machine: alias)

        if mode == .alwaysSSH || client == nil {
            let reason: MoshFallbackReason? = mode == .alwaysSSH ? nil : .noClient
            startSSH(kind, in: term, reason: reason,
                     detail: reason == nil ? "" : "No mosh-client in the app, /opt/homebrew/bin or /usr/local/bin.",
                     fresh: false)
            return
        }

        RemoteTransportStore.shared.connecting(kind, machine: alias)
        term.feed(text: "\u{1b}[2mConnecting to \(alias)\u{2026}\u{1b}[0m\r\n")
        let workspace = settings?.workspaceName(forAlias: alias) ?? alias
        let sshEnvironment = RemoteCommands.sshEnvironment(customSocket: customSocket)
        let cli = try? DevmachineCLI.resolve(customSocket: customSocket)
        Task.detached {
            let machine = cli.flatMap { cli in
                MachineDirectory.shared.machine(forWorkspace: workspace) {
                    (try? cli.listWorkspaces()).map { list in
                        Dictionary(list.map { ($0.name, $0.machine) }, uniquingKeysWith: { first, _ in first })
                    }
                }
            }
            let key = machine ?? alias
            let remembered = await MainActor.run { RemoteTransportStore.shared.remembered(for: key) }
            let plan = RemoteTransportPolicy.plan(mode: mode, remembered: remembered, clientPath: client)
            guard case let .mosh(clientPath, watchdog) = plan else {
                if case let .ssh(reason) = plan {
                    await TerminalRegistry.shared.finishRemote(
                        kind, id: id, machine: key,
                        result: .ssh(reason: reason ?? .noClient, detail: "", strayServerPID: nil),
                        fresh: false, client: "", watchdog: false, customSocket: customSocket)
                }
                return
            }
            let connector = MoshConnector(
                runner: ProcessRunner(), sshEnvironment: sshEnvironment,
                cliExecutable: cli?.executable, cliEnvironment: cli?.environment(),
                resolveSupport: TerminalRegistry.resolveSupport)
            let result = connector.connect(alias: alias, session: session, machine: machine)
            await TerminalRegistry.shared.finishRemote(
                kind, id: id, machine: key, result: result, fresh: true,
                client: clientPath, watchdog: watchdog, customSocket: customSocket)
        }
    }

    private func finishRemote(
        _ kind: TerminalKind, id: UUID, machine: String, result: MoshConnector.Result,
        fresh: Bool, client: String, watchdog: Bool, customSocket: String?
    ) {
        guard var launch = remoteLaunches[kind], launch.id == id, let term = terminals[kind] else {
            if case let .mosh(_, session) = result, case let .remote(alias, _) = kind {
                Self.endStrayServer(alias: alias, pid: session.serverPID)
            }
            return
        }
        launch.machine = machine
        switch result {
        case let .mosh(ip, session):
            launch.probing = watchdog
            launch.strayServerPID = session.serverPID
            remoteLaunches[kind] = launch
            PaneLog.log("mosh pane=\(kind) ip=\(ip) port=\(session.port)")
            term.startProcess(
                executable: client,
                args: MoshBootstrap.clientArguments(ip: ip, session: session),
                environment: MoshBootstrap.clientEnvironment(
                    session: session,
                    base: RemoteCommands.terminalEnvironment(
                        term: RemoteCommands.remoteTerm, customSocket: customSocket)))
            RemoteTransportStore.shared.usingMosh(kind, machine: machine)
            settleWarm(kind, running: true, via: .moshReady)
            if watchdog {
                DispatchQueue.main.asyncAfter(deadline: .now() + MoshClientProbe.timeout) { [weak self] in
                    self?.checkMosh(kind, id: id, ip: ip, port: session.port)
                }
            }
        case let .ssh(reason, detail, stray):
            // The person's one try was refused: the workspace's pause starts
            // again, and the ssh fallback would be a second refused login.
            // Coming back to the pane tries again.
            if case let .remote(alias, _) = kind, result.isRefusedLogin {
                AppModel.shared?.noteSSHFailure(alias: alias, .authDenied)
                remoteLaunches[kind] = nil
                RemoteTransportStore.shared.forget(kind)
                term.feed(text: "\u{1b}[2mLogin refused for \(alias). Paused checking it so the machine "
                    + "doesn't block this Mac's IP.\u{1b}[0m\r\n")
                dead.insert(kind)
                settleWarm(kind, running: false, via: .refused)
                return
            }
            launch.strayServerPID = stray
            remoteLaunches[kind] = launch
            startSSH(kind, in: term, reason: reason, detail: detail, fresh: fresh)
        }
    }

    /// mosh-client writes its "Nothing received from server" line on the top
    /// row until the first packet arrives, so the screen says whether the
    /// UDP path works.
    private func checkMosh(_ kind: TerminalKind, id: UUID, ip: String, port: Int) {
        guard var launch = remoteLaunches[kind], launch.id == id, launch.probing,
              let term = terminals[kind]
        else { return }
        launch.probing = false
        remoteLaunches[kind] = launch
        guard term.searchMatchSummary(MoshClientProbe.connectingMarker).total > 0 else {
            RemoteTransportStore.shared.moshConfirmed(machine: launch.machine)
            return
        }
        // The timer started this ssh, not the person: a paused workspace
        // waits for Try again instead of one more login.
        if case let .remote(alias, _) = kind, AppModel.shared?.isPollingPaused(alias: alias) == true {
            PaneLog.log("mosh silent pane=\(kind), ssh held while the workspace is paused")
            return
        }
        PaneLog.log("mosh silent pane=\(kind), switching to ssh")
        switchToSSH(kind, reason: .udpBlocked,
                    detail: "mosh-client sent to \(ip) UDP port \(port) and got nothing back "
                        + "in \(Int(MoshClientProbe.timeout)) seconds.")
    }

    /// Stops mosh-client at once: on SIGTERM it would first wait for the
    /// server to acknowledge a shutdown that can never arrive. The ssh starts
    /// from `processTerminated`, the one moment the view can run a new process.
    private func switchToSSH(_ kind: TerminalKind, reason: MoshFallbackReason, detail: String) {
        guard var launch = remoteLaunches[kind], let term = terminals[kind] else { return }
        launch.next = .ssh(reason: reason, detail: detail)
        remoteLaunches[kind] = launch
        let pid = term.process.shellPid
        if pid > 0 { kill(pid, SIGKILL) } else { term.terminate() }
    }

    /// A manual "Try mosh again": the pane's process stops and the whole
    /// choice runs again.
    func restart(_ kind: TerminalKind) {
        guard let term = terminals[kind] else { return }
        guard term.process.running, var launch = remoteLaunches[kind] else {
            dead.remove(kind)
            start(kind, in: term)
            return
        }
        launch.probing = false
        launch.next = .restart
        remoteLaunches[kind] = launch
        term.terminate()
    }

    private func startSSH(
        _ kind: TerminalKind, in term: LocalProcessTerminalView, reason: MoshFallbackReason?,
        detail: String, fresh: Bool
    ) {
        guard let launch = remoteLaunches[kind] else { return }
        let customSocket = SettingsStore.shared.settings?.sshAgentSocket
        term.startProcess(
            executable: "/usr/bin/ssh",
            args: [launch.alias, "-t",
                   MoshBootstrap.sshFallbackCommand(session: launch.session, strayServerPID: launch.strayServerPID)],
            environment: RemoteCommands.terminalEnvironment(
                term: RemoteCommands.remoteTerm, customSocket: customSocket))
        RemoteTransportStore.shared.usingSSH(
            kind, machine: launch.machine, reason: reason, detail: detail, fresh: fresh)
    }

    /// Answers the exit of a remote pane's process when the app caused it
    /// or was waiting on it. Returns false for an ordinary exit.
    private func handleRemoteExit(_ kind: TerminalKind, source: TerminalView, exitCode: Int32?) -> Bool {
        guard var launch = remoteLaunches[kind], let term = terminals[kind] else { return false }
        let next: RemoteLaunch.Next
        if let planned = launch.next {
            next = planned
        } else if launch.probing {
            next = .ssh(reason: .clientExited,
                        detail: "mosh-client exited with status \(exitCode.map(String.init) ?? "?") "
                            + "before it heard from the server.")
        } else {
            return false
        }
        launch.next = nil
        launch.probing = false
        remoteLaunches[kind] = launch
        switch next {
        case let .ssh(reason, detail):
            PaneLog.log("ssh after mosh pane=\(kind) reason=\(reason)")
            term.feed(text: Self.leaveMoshScreen)
            startSSH(kind, in: term, reason: reason, detail: detail, fresh: true)
        case .restart:
            term.feed(text: Self.leaveMoshScreen)
            start(kind, in: term)
        }
        return true
    }

    /// A killed mosh-client leaves the terminal in its alternate screen with
    /// the cursor hidden; this puts it back before the next program draws.
    private static let leaveMoshScreen = "\u{1b}[?1049l\u{1b}[?1l\u{1b}>\u{1b}[?25h\u{1b}[2J\u{1b}[H"

    /// A pane closed while mosh-server was starting leaves a server nobody
    /// will reach, holding a tmux client until its own timeout.
    nonisolated private static func endStrayServer(alias: String, pid: Int?) {
        guard let pid else { return }
        let environment = RemoteCommands.sshEnvironment()
        Task.detached {
            _ = try? ProcessRunner().run(
                executable: "/usr/bin/ssh",
                args: RemoteCommands.sshBaseArgs(alias: alias) + ["kill \(pid) 2>/dev/null"],
                environment: environment)
        }
    }
}

/// What released a warm terminal, named in the log line.
enum WarmSettleCause: String {
    case moshReady = "mosh-ready"
    case bytes
    case timeout
    case refused
    case exit
    case closed
}

struct PendingWarm {
    let settled: (Bool) -> Void
    let since: Date
}

extension TerminalRegistry: @preconcurrency LocalProcessTerminalViewDelegate {
    /// The size the program itself is told. The pane's frame in points is not
    /// that number, and the difference is what a half-drawn screen is made of.
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        let kind = terminals.first { $0.value === source }?.key
        PaneLog.log("pty size pane=\(kind.map(String.init(describing:)) ?? "?") "
            + "cols=\(newCols) rows=\(newRows)")
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // A dead process must not be handed out again: the next mount starts a
    // fresh one.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // The view stays: the session it was showing usually outlived the
        // client (tmux and zmx both do), so coming back should reconnect rather
        // than leave a dead screen or lose the pane.
        guard let kind = terminals.first(where: { $0.value === source })?.key else { return }
        PaneLog.log("process ended pane=\(kind) exit=\(exitCode.map(String.init) ?? "-")")
        if handleRemoteExit(kind, source: source, exitCode: exitCode) { return }
        settleWarm(kind, running: false, via: .exit)
        dead.insert(kind)
        detachedAt[kind] = nil
        if case let .local(session, _) = kind {
            closeIfSessionIsGone(kind, session: session)
        }
    }

    /// Telling the two endings apart: the client stopped, or the shell itself
    /// ended (`exit`). Only the multiplexer knows, so it is asked. A session
    /// that is gone takes its pane with it.
    private func closeIfSessionIsGone(_ kind: TerminalKind, session: String) {
        guard let zmx = LocalTools.zmxPath() else {
            // No multiplexer: the shell was the session, so it ended with it.
            sessionDidEnd(kind)
            return
        }
        let socketDirectory = Zmx.socketDirectory()
        let name = Zmx.sessionName(from: session, socketDirectory: socketDirectory)
        Task.detached {
            let listing = (try? ProcessRunner().run(
                executable: zmx, args: Zmx.listArguments,
                environment: ["ZMX_DIR": socketDirectory])) ?? ""
            let alive = ZmxListParser.parse(listing).contains { $0.name == name }
            guard !alive else { return }
            await MainActor.run { TerminalRegistry.shared.sessionDidEnd(kind) }
        }
    }

    private func sessionDidEnd(_ kind: TerminalKind) {
        PaneLog.log("session ended pane=\(kind)")
        close(kind)
        onSessionEnded?(kind)
    }
}

// Coding harnesses can turn on the kitty keyboard protocol when available,
// and tmux forwards it to any client whose XTVERSION reply says "XTerm(...)".
// SwiftTerm's kitty encoding still breaks Enter and dead keys, so the view
// drops both replies: programs keep the legacy encoding this app always ran.
final class LegacyKeyboardTerminalView: SelectingTerminalView {
    /// The session this view shows, so a link can be resolved in its folder.
    var kind: TerminalKind?

    override func openRequestedLink(_ link: String, params: [String: String]) {
        TerminalRegistry.shared.openLink(link, from: kind, flags: NSEvent.modifierFlags)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(openFind), keyEquivalent: "f")
        find.target = self
        menu.addItem(find)
        return menu
    }

    @objc private func openFind() {
        guard let kind else { return }
        AppModel.shared?.findTarget = kind
    }

    /// The rows and columns handed to the program, logged as they are. An
    /// earlier version refused small sizes and returned the last good one; that
    /// made SwiftTerm believe the program had already been told the real size,
    /// so when the pane settled nothing was sent and every pane stayed blank.
    override func getWindowSize() -> winsize {
        let size = super.getWindowSize()
        PaneLog.log("window size cols=\(size.ws_col) rows=\(size.ws_row)")
        return size
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let filtered = TerminalReplyFilter.strip(Array(data))
        guard !filtered.isEmpty else { return }
        super.send(source: source, data: filtered[...])
    }
}

/// Tools the app carries in its own bundle rather than expecting on the Mac.
enum LocalTools {
    static func moshClientPath(bundle: Bundle = .main) -> String {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/mosh-client").path
    }

    static func zmxPath(
        bundle: Bundle = .main,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        guard let url = bundle.url(forResource: "zmx", withExtension: nil, subdirectory: "zmx"),
              exists(url.path)
        else { return nil }
        return url.path
    }

    /// Read once per run: the user database lookup is not free, and a changed
    /// login shell takes a new login anyway.
    static let accountShell = LocalShell.current()

    /// Checked at every pane start, since a shell pointed at a missing file
    /// loses the user's configuration; unchanged files cost a read. A write
    /// that fails starts the shell without the integration instead.
    static func shellLaunch() -> ShellLaunch {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let directory = support.appendingPathComponent("Devmachine/shell-integration")
        var installed: String?
        do {
            try ShellIntegration.install(in: directory)
            installed = directory.path
        } catch {
            PaneLog.log("shell integration not written: \(error)")
        }
        return ShellIntegration.launch(shell: accountShell, integrationDirectory: installed)
    }
}

enum TerminalKeyboard {
    /// Option means Meta only together with a function key (arrows, F-keys); on
    /// its own it is the accent composer of the Mac's keyboard layout.
    static func optionActsAsMeta(for flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option) && flags.contains(.function)
    }

    /// ⌘F, and only ⌘F: ⌥⌘F and ⌃⌘F belong to whatever runs in the session.
    static func opensFind(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == findKeyCode
            && flags.contains(.command)
            && !flags.contains(.option) && !flags.contains(.control) && !flags.contains(.shift)
    }

    static let findKeyCode: UInt16 = 3

    static let returnKeyCode: UInt16 = 36

    /// A newline byte understood by supported coding harnesses as inserted input.
    static let newlineBytes: [UInt8] = [0x0A]

    static let pageUpKeyCode: UInt16 = 116
    static let pageDownKeyCode: UInt16 = 121

    /// What a terminal sends for Page Up and Page Down. Plain keys only: with a
    /// modifier they mean something else (⇧⇞ is the terminal's own scroll).
    static func pageKeyBytes(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> [UInt8]? {
        guard flags.intersection([.command, .control, .shift, .option]).isEmpty else { return nil }
        switch keyCode {
        case pageUpKeyCode: return Array("\u{1b}[5~".utf8)
        case pageDownKeyCode: return Array("\u{1b}[6~".utf8)
        default: return nil
        }
    }

    /// The legacy key encoding this app keeps on purpose cannot tell Shift+Enter
    /// from Enter, so the terminal sends the newline byte itself. Enter alone
    /// still submits, and Command+Shift+Return stays an app shortcut.
    static let vKeyCode: UInt16 = 9

    /// Command+V, the paste the app answers itself when the clipboard holds an
    /// image. Everything else still reaches SwiftTerm's own paste.
    static func pastesClipboard(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        return keyCode == vKeyCode
            && mods.contains(.command)
            && !mods.contains(.shift)
            && !mods.contains(.control)
            && !mods.contains(.option)
    }

    static func sendsNewline(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        return keyCode == returnKeyCode
            && mods.contains(.shift)
            && !mods.contains(.command)
            && !mods.contains(.control)
            && !mods.contains(.option)
    }
}
