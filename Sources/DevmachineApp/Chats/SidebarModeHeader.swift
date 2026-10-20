import SwiftUI
import DevmachineCore

/// The sidebar's first row in every mode: "CODE WORKSPACES ▾", "CHAT
/// WORKSPACES ▾" or "SCHEDULE ▾", which opens the mode menu, then refresh at
/// the right. In Chats, a dot by the title says a session in Code
/// waits for the person.
struct SidebarModeHeader: View {
    let refresh: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dmMetrics) private var m

    static func title(_ mode: AppMode) -> String {
        switch mode {
        case .code: return "CODE WORKSPACES"
        case .chats: return "CHAT WORKSPACES"
        case .schedule: return "SCHEDULE"
        }
    }

    static func name(_ mode: AppMode) -> String {
        switch mode {
        case .code: return "Code"
        case .chats: return "Chats"
        case .schedule: return "Schedule"
        }
    }

    static func accessibilityValue(_ mode: AppMode, codeWaits: Bool) -> String {
        let current = "current: " + name(mode)
        return mode != .code && codeWaits ? current + ", a session in Code is waiting" : current
    }

    var body: some View {
        HStack(spacing: m.space.sm) {
            ChatDropdown(
                items: SidebarModeMenuOverlay.items(model), accessibilityLabel: "Switch mode",
                accessibilityValue: Self.accessibilityValue(model.appMode, codeWaits: model.codeNeedsAttention),
                accessibilityHint: "Command-1 for Code, Command-2 for Chats, Command-3 for Schedule",
                help: "Code, Chats or Schedule (⌘1, ⌘2, ⌘3)", toggleDrawn: { model.showsModeMenu.toggle() }
            ) {
                HStack(spacing: m.pt(5)) {
                    Text(verbatim: Self.title(model.appMode))
                        .font(.dm(11, weight: .semibold))
                        .kerning(0.8)
                    Image(systemName: "chevron.down")
                        .font(.dm(8, weight: .bold))
                    if model.appMode != .code, model.codeNeedsAttention {
                        Circle()
                            .fill(Color(hex: 0x3B82F6))
                            .frame(width: m.pt(6), height: m.pt(6))
                            .dmHelp("A session in Code is waiting for you")
                    }
                }
                .foregroundStyle(model.showsModeMenu ? Color.dmRowText : Color.dmMuted)
                .contentShape(Rectangle())
            }
            .anchorPreference(key: SidebarModeMenuAnchor.self, value: .bounds) { $0 }
            .demoClickTarget("sidebar:mode")
            Spacer(minLength: m.space.sm)
            DMIconButton(systemImage: "arrow.clockwise", size: DMMetrics.baseFontSize, action: refresh)
                .dmHelp("Refresh")
                .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, m.pt(12))
    }
}

/// "New session" in Code and "New chat" in Chats, under the header.
struct SidebarNewRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    var selected = false
    let action: () -> Void
    @Environment(\.dmMetrics) private var m

    private var row: some View {
        HStack(spacing: m.pt(8)) {
            Image(systemName: systemImage).font(.dm(12, weight: .medium))
            Text(verbatim: title).font(.dm(13, weight: .medium))
            Spacer()
            if let shortcut {
                Text(verbatim: shortcut).font(.dm(11)).foregroundStyle(Color.dmMuted)
            }
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, m.pt(10))
        .frame(height: m.pt(32))
        .dmSurface(selected ? Color.white.opacity(0.1) : Color.white.opacity(0.07), radius: DMRadius.control)
        .contentShape(Rectangle())
    }

    var body: some View {
        Button(action: action) { row }
            .buttonStyle(.plain)
            .padding(.horizontal, m.pt(10))
            .dmHelp(shortcut.map { "\(title) (\($0))" } ?? title)
            .accessibilityLabel(title)
            .accessibilityHint(shortcut.map { "Shortcut \($0)" } ?? "")
    }
}

struct SidebarModeMenuAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The menu under the header title, drawn in the window so a click
/// anywhere else closes it and a demo frame can show it open.
struct SidebarModeMenuOverlay: ViewModifier {
    @ObservedObject var model: AppModel
    @Environment(\.dmMetrics) private var m

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(SidebarModeMenuAnchor.self) { anchor in
            if DemoMode.isActive, model.showsModeMenu, let anchor {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .onTapGesture { model.showsModeMenu = false }
                        ChatMenuCard(items: items, width: 220, highlighted: highlighted)
                            .offset(x: rect.minX - m.pt(6), y: rect.maxY + m.pt(6))
                    }
                }
            }
        }
    }

    private var highlighted: String { "mode-" + model.appMode.rawValue }

    private var items: [ChatMenuItem] { Self.items(model) }

    static func items(_ model: AppModel) -> [ChatMenuItem] {
        var items = [
            ChatMenuItem(
                id: "mode-code", title: "Code", systemImage: "chevron.left.forwardslash.chevron.right",
                checked: model.appMode == .code, shortcut: "⌘1",
                action: { model.showsModeMenu = false; model.appMode = .code }),
            ChatMenuItem(
                id: "mode-chats", title: "Chats", systemImage: "bubble.left.and.bubble.right",
                checked: model.appMode == .chats, shortcut: "⌘2",
                action: { model.showsModeMenu = false; model.showChats() }),
            ChatMenuItem(
                id: "mode-schedule", title: "Schedule", systemImage: "clock",
                checked: model.appMode == .schedule, shortcut: "⌘3",
                action: { model.showsModeMenu = false; model.showPage(.scheduled) }),
        ]
        if model.appMode == .code {
            items += [
                .separator("mode-sep"),
                ChatMenuItem(
                    id: "new-workspace", title: "New workspace…", systemImage: "person.crop.square.badge.plus",
                    choice: false, action: { model.showsModeMenu = false; model.requestNewWorkspace() }),
            ]
        }
        return items
    }
}

/// Shows or hides the sidebar, in the title bar band on the window
/// buttons' line: at the sidebar's right edge while it is open, right after
/// the window buttons while it is closed.
struct SidebarToggleButton: View {
    @EnvironmentObject private var model: AppModel

    static func label(collapsed: Bool) -> String { collapsed ? "Show sidebar" : "Hide sidebar" }

    var body: some View {
        DMIconButton(systemImage: "sidebar.left", size: 13, hitSize: CGSize(width: 24, height: 24)) {
            withAnimation(.easeInOut(duration: 0.18)) { model.sidebarCollapsed.toggle() }
        }
        .dmHelp(Self.label(collapsed: model.sidebarCollapsed) + " (⌘B)")
        .accessibilityLabel(Self.label(collapsed: model.sidebarCollapsed))
        .demoClickTarget("footer:close-sidebar")
    }
}

/// Where the toggle's center goes, in points from the window's top left.
enum SidebarTogglePlacement {
    static let hit: CGFloat = 24
    static let gapAfterButtons: CGFloat = 14
    static let rightPadding: CGFloat = 12

    static func center(collapsed: Bool, sidebarWidth: CGFloat, buttons: CGRect) -> CGPoint {
        let x = collapsed
            ? buttons.maxX + gapAfterButtons + hit / 2
            : sidebarWidth - rightPadding - hit / 2
        return CGPoint(x: x, y: buttons.midY)
    }
}

/// The window's close, minimise and zoom buttons, in points from the top
/// left of the window, read where macOS put them (the toolbar moves them).
/// It also keeps the title bar see-through, so each mode's own surface runs
/// up under it.
struct WindowButtonsReader: NSViewRepresentable {
    @Binding var frame: CGRect

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { frame = $0 }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = { frame = $0 }
    }

    final class ReaderView: NSView {
        var onChange: (CGRect) -> Void = { _ in }
        private var last: CGRect = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowChanged), name: name, object: window)
            }
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(fullScreenWillChange(_:)), name: name, object: window)
            }
            window.toolbar?.isVisible = !window.styleMask.contains(.fullScreen)
            windowChanged()
        }

        override func layout() {
            super.layout()
            windowChanged()
        }

        /// Full screen hides the toolbar: macOS keeps a visible toolbar on
        /// screen there as an opaque band that pushes every column down. The
        /// window buttons still slide in with the menu bar without it.
        @objc private func fullScreenWillChange(_ notification: Notification) {
            window?.toolbar?.isVisible = notification.name == NSWindow.willExitFullScreenNotification
        }

        @objc private func windowChanged() {
            guard let window, let frameView = window.contentView?.superview else { return }
            // In full screen the buttons live in the title bar's own window, so
            // converting them to this one gives a point far down the screen.
            // The layout keeps the windowed place instead.
            if window.styleMask.contains(.fullScreen) {
                report(last == .zero ? SidebarHeaderSpacing.fallbackButtons : last)
                return
            }
            let rects = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> CGRect? in
                guard let button = window.standardWindowButton(type), !button.isHidden else { return nil }
                let rect = button.convert(button.bounds, to: frameView)
                let top = frameView.isFlipped ? rect.minY : frameView.bounds.height - rect.maxY
                return CGRect(x: rect.minX, y: top, width: rect.width, height: rect.height)
            }
            guard let first = rects.first else { return }
            report(rects.dropFirst().reduce(first) { $0.union($1) })
        }

        private func report(_ union: CGRect) {
            guard union != last else { return }
            last = union
            DispatchQueue.main.async { [onChange] in onChange(union) }
        }
    }
}

private struct SidebarHeaderTopKey: EnvironmentKey {
    static let defaultValue: CGFloat = SidebarHeaderSpacing.fallback
}

private struct TitleLineKey: EnvironmentKey {
    static let defaultValue: CGFloat = SidebarHeaderSpacing.fallbackLine
}

extension EnvironmentValues {
    /// The window buttons' vertical center, in points from the window's top:
    /// the line the title bar's controls sit on.
    var titleLine: CGFloat {
        get { self[TitleLineKey.self] }
        set { self[TitleLineKey.self] = newValue }
    }

    /// Where the sidebar's header starts, in points from the window's top:
    /// close under the window buttons. The sidebars run under the title bar.
    var sidebarHeaderTop: CGFloat {
        get { self[SidebarHeaderTopKey.self] }
        set { self[SidebarHeaderTopKey.self] = newValue }
    }
}

/// The sidebar's top block (title, then the New row) keeps the same space
/// above it, under the window buttons, as below it, before the list.
enum SidebarHeaderSpacing {
    /// Under the New row, before the list.
    static let blockGap: CGFloat = 14
    /// The list's first group header has more room above its text than the
    /// title row has; this evens the two, so the gaps read the same.
    static let textAlignment: CGFloat = 9.5
    static let fallback: CGFloat = 52
    static let fallbackLine: CGFloat = 22
    /// The window buttons' place when there is none to read (a window that
    /// opens in full screen), matching the fallbacks above.
    static let fallbackButtons = CGRect(x: 20, y: fallbackLine - 7, width: 52, height: 14)

    static func line(buttons: CGRect) -> CGFloat {
        buttons == .zero ? fallbackLine : buttons.midY
    }

    static func top(buttons: CGRect) -> CGFloat {
        buttons == .zero ? fallback : buttons.maxY + blockGap + textAlignment
    }
}

struct SidebarHeaderTop: ViewModifier {
    @Environment(\.sidebarHeaderTop) private var top

    func body(content: Content) -> some View {
        content.padding(.top, top)
    }
}

/// A sidebar column drawn from the window's top edge, under the window
/// buttons, with its header placed by `SidebarHeaderTop`.
struct SidebarUnderTitlebar: ViewModifier {
    func body(content: Content) -> some View {
        content.ignoresSafeArea(edges: .top)
    }
}
