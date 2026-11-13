import SwiftUI
import AppKit

/// A click target for a control laid under the see-through toolbar band.
/// A SwiftUI tap there never fired: the window server drags the window from
/// any part of the band no AppKit view claims, and a click that reaches the
/// app hits the toolbar's own view, which sits over the content. This lays a
/// real NSView over the control that claims its bounds the way
/// `SelectingTerminalView` does, gets the press from `TitlebarClickRouter`,
/// and runs the action itself on release. The empty band around it still
/// drags the window.
struct TitlebarClickTarget: NSViewRepresentable {
    let action: () -> Void
    /// Items for a right click, each a title and what it does.
    var menu: [(String, () -> Void)] = []

    func makeNSView(context: Context) -> TitlebarClickTargetView {
        let view = TitlebarClickTargetView()
        view.action = action
        view.menuItems = menu
        return view
    }

    func updateNSView(_ nsView: TitlebarClickTargetView, context: Context) {
        nsView.action = action
        nsView.menuItems = menu
    }
}

final class TitlebarClickTargetView: NSView {
    var action: () -> Void = {}
    var menuItems: [(String, () -> Void)] = []
    private var pressed = false

    /// AppKit has no public way to claim part of the band; NSButton claims its
    /// bounds through this same private method (`SelectingTerminalView` too).
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect {
        bounds
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { TitlebarClickRouter.shared.register(self) }
    }

    /// Its spot in window coordinates, or nil while it is off screen.
    var rectInWindow: NSRect? {
        guard window != nil, !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0 else { return nil }
        return convert(bounds, to: nil)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuItems.isEmpty else { return nil }
        let menu = NSMenu()
        for (title, run) in menuItems {
            let item = NSMenuItem(title: title, action: #selector(TitlebarMenuAction.run), keyEquivalent: "")
            let target = TitlebarMenuAction(run)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        return menu
    }
}

/// Hands a press inside a `TitlebarClickTargetView` straight to it. The
/// claim keeps the window server from dragging the window, but inside the
/// app the toolbar's own view sits over the content and is what a click in
/// the band hits. It passes the click on only to the spots it knew when it
/// last measured them, so a tab opened later went to the toolbar.
@MainActor
final class TitlebarClickRouter {
    static let shared = TitlebarClickRouter()

    private final class Weak {
        weak var view: TitlebarClickTargetView?
        init(_ view: TitlebarClickTargetView) { self.view = view }
    }

    private var targets: [Weak] = []
    private var monitor: Any?
    private weak var pressed: TitlebarClickTargetView?

    func register(_ view: TitlebarClickTargetView) {
        targets.removeAll { $0.view == nil || $0.view === view }
        targets.append(Weak(view))
        guard monitor == nil else { return }
        // Local monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { TitlebarClickRouter.shared.route(event) }
            return handled ? nil : event
        }
    }

    /// True when the event went to a target here and must go no further.
    func route(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            pressed = target(at: event)
            guard let pressed else { return false }
            pressed.mouseDown(with: event)
            return true
        case .leftMouseUp:
            guard let target = pressed else { return false }
            pressed = nil
            target.mouseUp(with: event)
            return true
        case .rightMouseDown:
            guard let target = target(at: event), let menu = target.menu(for: event) else { return false }
            NSMenu.popUpContextMenu(menu, with: event, for: target)
            return true
        default:
            return false
        }
    }

    /// The smallest target under the press in the event's window.
    func target(at event: NSEvent) -> TitlebarClickTargetView? {
        guard let window = event.window else { return nil }
        let point = event.locationInWindow
        return targets
            .compactMap { weak -> (TitlebarClickTargetView, NSRect)? in
                guard let view = weak.view, view.window === window, let rect = view.rectInWindow,
                      rect.contains(point) else { return nil }
                return (view, rect)
            }
            .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }
}

private final class TitlebarMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

extension View {
    /// Runs `action` on a click even while this view sits under the toolbar
    /// band (`TitlebarClickTarget`).
    func titlebarClick(menu: [(String, () -> Void)] = [], perform action: @escaping () -> Void) -> some View {
        overlay(TitlebarClickTarget(action: action, menu: menu))
    }
}
