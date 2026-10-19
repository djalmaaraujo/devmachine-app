import AppKit
import Combine
import SwiftUI
import DevmachineCore

/// What the quick panel shows: one question, its streamed answer, and
/// where it goes (a new chat, or a recent one picked under "New chat ▾").
@MainActor
final class QuickChatModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var chatKey: String?
    @Published var continuing: String?
    @Published var harness: HarnessID? { didSet { warm() } }
    @Published var place: ChatPlace? { didSet { warm() } }
    @Published var showsChooser = false
    @Published private(set) var question: String?
    /// Goes up each time the panel opens, so its field takes the keyboard
    /// again, not only the first time the view appears.
    @Published private(set) var focusRequests = 0

    let store: ChatStore
    var openInApp: (String?) -> Void = { _ in }
    var close: () -> Void = {}

    init(store: ChatStore) {
        self.store = store
    }

    var chatID: String? { chatKey.map(store.current) }

    var conversation: ChatConversation? { chatID.map(store.conversation) }

    var isStreaming: Bool { chatID.map(store.isAnswering) ?? false }

    var isContinuing: Bool { continuing != nil || chatKey != nil }

    var shownHarness: HarnessID {
        if let id = chatID ?? continuing, let record = store.record(id) { return record.harness }
        return harness.flatMap { store.settings.harnesses.contains($0) ? $0 : nil } ?? store.settings.harnesses[0]
    }

    var shownPlace: ChatPlace {
        if let id = chatID ?? continuing, let record = store.record(id) { return record.place }
        return place ?? store.defaultPlace
    }

    var recentChats: [ChatRecord] { Array(store.visibleChats.prefix(4)) }

    var usesMCP: Bool { store.usesMCP(chatID ?? continuing) }

    func toggleMCP() {
        store.setMCP(!usesMCP, chat: chatID ?? continuing)
        warm()
    }

    /// The panel's next message starts at once: its chat's session, or a warm
    /// one for a new chat with the panel's harness, workspace and MCP.
    func warm() {
        if let id = chatID ?? continuing {
            store.warmChat(id)
        } else {
            store.prewarm(ChatSessionSpec(harness: shownHarness, place: shownPlace, mcp: usesMCP))
        }
    }

    /// A fresh panel, unless an answer is still coming into it.
    func prepareForShow() {
        guard !isStreaming else { return }
        text = ""
        chatKey = nil
        continuing = nil
        question = nil
        showsChooser = false
        store.openPicker = nil
    }

    func requestFocus() {
        focusRequests += 1
    }

    func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isStreaming else { return }
        let key: String?
        if let target = chatID ?? continuing {
            key = store.send(body, toChat: target)
        } else {
            key = store.send(body, harness: shownHarness, place: shownPlace, selects: false)
        }
        guard let key else { return }
        chatKey = key
        continuing = nil
        question = body
        text = ""
        showsChooser = false
    }

    func stop() {
        if let chatID { store.stop(chatID) }
    }

    func startNew() {
        continuing = nil
        chatKey = nil
        question = nil
        showsChooser = false
        warm()
    }

    func continueChat(_ id: String) {
        continuing = id
        chatKey = nil
        question = nil
        showsChooser = false
        store.loadIfNeeded(id)
        warm()
    }

    func openCurrentInApp() {
        openInApp(chatID ?? continuing)
    }

    func seedDemo(chatKey: String?, question: String?, showsChooser: Bool = false) {
        self.chatKey = chatKey
        self.question = question
        self.showsChooser = showsChooser
        continuing = nil
    }
}

final class QuickChatWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The floating panel the global shortcut opens over any app. It never
/// activates Devmachine, so the app in front keeps its place.
@MainActor
final class QuickChatPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickChatPanelController()
    static let cardWidth: CGFloat = 680
    static let margin: CGFloat = 24
    private static let screenGap: CGFloat = 32

    /// The card and its shadow margin grow with the app's font size, so the
    /// window has to grow with them or the card is cut at both sides.
    static func width(_ metrics: DMMetrics, fitting screenWidth: CGFloat) -> CGFloat {
        min(metrics.pt(cardWidth) + 2 * metrics.pt(margin), screenWidth - screenGap)
    }

    private var metrics = DMMetrics(scale: 1)

    let model = QuickChatModel(store: .shared)
    private var panel: QuickChatWindow?
    /// The app that was in front when the shortcut opened the panel.
    private var returnTo: NSRunningApplication?
    private var hotkeys: QuickChatHotkeyController?
    private var settings: AnyCancellable?

    func start(registrar: any HotkeyRegistering = CarbonHotkeyRegistrar()) {
        guard hotkeys == nil else { return }
        let controller = QuickChatHotkeyController(registrar: registrar) { [weak self] in self?.toggle() }
        hotkeys = controller
        model.close = { [weak self] in self?.dismiss() }
        model.openInApp = { [weak self] id in self?.openInApp(id) }
        settings = SettingsStore.shared.$settings.sink { settings in
            let chats = settings?.chats ?? .default
            ChatStore.shared.settings = chats
            controller.apply(chats)
        }
    }

    var isShown: Bool { panel?.isVisible == true }

    func suspendHotkey(_ suspended: Bool) {
        guard let hotkeys else { return }
        if suspended {
            hotkeys.suspend()
        } else {
            hotkeys.apply(SettingsStore.shared.settings?.chats ?? .default)
        }
    }

    func toggle() {
        if isShown, panel?.isKeyWindow == true { hide() } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        returnTo = Self.returnsFocus(toPID: front?.processIdentifier) ? front : nil
        model.prepareForShow()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyFontSize(to: panel)
        Task { await ChatStore.shared.refresh() }
        position(panel, height: panel.frame.height)
        panel.makeKeyAndOrderFront(nil)
        focusField(in: panel)
        model.warm()
    }

    func hide() {
        model.showsChooser = false
        panel?.orderOut(nil)
    }

    /// Esc: the panel goes away and the app that was in front gets the
    /// keyboard back.
    func dismiss() {
        hide()
        returnTo?.activate()
        returnTo = nil
    }

    /// Only another app gets the keyboard back; Devmachine in front keeps it.
    nonisolated static func returnsFocus(
        toPID pid: pid_t?, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        guard let pid else { return false }
        return pid != ownPID
    }

    /// SwiftUI's focus binding runs before the panel is key the first time
    /// and never again for a reused panel; the field is made first responder
    /// once the panel is key, on every open.
    private func focusField(in panel: QuickChatWindow) {
        model.requestFocus()
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isKeyWindow, !(panel.firstResponder is NSText) else { return }
            if let field = panel.contentView.flatMap(Self.firstTextField) {
                panel.makeFirstResponder(field)
            }
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> QuickChatWindow {
        let panel = QuickChatWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 120),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.delegate = self
        installContent(in: panel)
        return panel
    }

    /// The font size can change in Settings after the panel was made.
    private func applyFontSize(to panel: QuickChatWindow) {
        let current = DMMetrics(scale: SettingsStore.shared.effectiveUIFontScale)
        guard current != metrics else { return }
        installContent(in: panel)
    }

    private func installContent(in panel: QuickChatWindow) {
        metrics = DMMetrics(scale: SettingsStore.shared.effectiveUIFontScale)
        let root = Self.content(model: model, metrics: metrics) { [weak self] height in self?.resize(to: height) }
        panel.contentView = NSHostingView(rootView: root)
    }

    static func content(
        model: QuickChatModel, metrics: DMMetrics, resize: @escaping (CGFloat) -> Void
    ) -> some View {
        QuickChatPanelView(model: model, resize: resize)
            .environment(\.dmMetrics, metrics)
            .environment(\.dmShowsHelp, false)
    }

    private func width(for screen: NSScreen?) -> CGFloat {
        Self.width(metrics, fitting: screen?.visibleFrame.width ?? .greatestFiniteMagnitude)
    }

    /// The panel sits in the upper third of the screen with the pointer and
    /// grows downward as the answer arrives.
    private func position(_ panel: NSPanel, height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let top = visible.maxY - visible.height * 0.22
        let width = width(for: screen)
        panel.setFrame(
            NSRect(x: visible.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    private func resize(to height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setFrame(
            NSRect(x: panel.frame.minX, y: top - height, width: panel.frame.width, height: height), display: true)
    }

    private func openInApp(_ id: String?) {
        hide()
        NSApp.activate(ignoringOtherApps: true)
        MainWindowOpener.open()
        if let id { AppModel.shared?.showChats(select: id) } else { AppModel.shared?.showNewChat() }
    }
}

/// Brings the main window back, reopening it when it was closed.
@MainActor
enum MainWindowOpener {
    static var openWindow: (() -> Void)?

    static func open() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
    }
}

struct QuickChatPanelView: View {
    @ObservedObject var model: QuickChatModel
    @ObservedObject private var store = ChatStore.shared
    let resize: (CGFloat) -> Void
    @Environment(\.dmMetrics) private var m
    @FocusState private var focused: Bool

    var body: some View {
        QuickChatCard(model: model, focused: $focused)
            .padding(m.pt(QuickChatPanelController.margin))
            .padding(.bottom, model.showsChooser || store.openPicker != nil ? m.pt(190) : 0)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resize($0) }
            .onAppear { focused = true }
            .onChange(of: model.focusRequests) { _, _ in focused = true }
            .onKeyPress(.escape) {
                if model.showsChooser || store.openPicker != nil {
                    model.showsChooser = false
                    store.openPicker = nil
                } else {
                    model.close()
                }
                return .handled
            }
            .environment(\.colorScheme, .dark)
    }
}

/// The panel itself, apart from its window, so the demo can draw it.
struct QuickChatCard: View {
    @ObservedObject var model: QuickChatModel
    var focused: FocusState<Bool>.Binding?
    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dmMetrics) private var m

    private var hotkey: String { store.settings.hotkey?.display ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if let conversation = model.conversation, model.question != nil {
                answer(conversation)
            }
            chipsRow
        }
        .frame(maxWidth: m.pt(QuickChatPanelController.cardWidth))
        .background(Color(hex: 0x1A2027).opacity(0.97), in: RoundedRectangle(cornerRadius: m.pt(DMRadius.bubble)))
        .overlay(RoundedRectangle(cornerRadius: m.pt(DMRadius.bubble)).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.55), radius: m.pt(30), y: m.pt(14))
        .overlay(alignment: .topTrailing) {
            if model.showsChooser {
                ChatMenuCard(items: chooserItems, width: 320, highlighted: model.continuing ?? model.recentChats.first?.id)
                    .offset(x: -m.pt(52), y: m.pt(52))
            }
        }
        .modifier(ChatPickerOverlay(
            store: store, harness: model.shownHarness, place: model.shownPlace, opensBelow: true,
            pickHarness: { model.harness = $0 }, pickPlace: { model.place = $0 }))
    }

    private var chooserItems: [ChatMenuItem] {
        var items: [ChatMenuItem] = [
            ChatMenuItem(
                id: "new", title: "New chat", systemImage: "square.and.pencil", checked: !model.isContinuing,
                shortcut: "⌘N", action: { model.startNew() }),
        ]
        let recent = model.recentChats
        if !recent.isEmpty {
            items += [.separator("sep"), .header("Continue")]
            items += recent.map { chat in
                ChatMenuItem(
                    id: chat.id, title: chat.title, detail: ChatGrouping.age(of: chat.updatedAt, now: Date()),
                    harness: chat.harness, checked: model.continuing == chat.id,
                    action: { model.continueChat(chat.id) })
            }
        }
        return items
    }

    private var inputRow: some View {
        HStack(spacing: m.pt(12)) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.dm(13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: m.pt(30), height: m.pt(30))
                .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: m.pt(DMRadius.control)))
            if model.isStreaming, let question = model.question {
                Text(verbatim: question)
                    .font(.dm(16))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                field
            }
            ChatDropdown(
                items: chooserItems, accessibilityLabel: "Conversation",
                accessibilityValue: model.isContinuing ? "Continuing a chat" : "New chat",
                accessibilityHint: "Start a new chat or continue a recent one",
                help: "New chat or continue a recent one", toggleDrawn: { model.showsChooser.toggle() }
            ) {
                ChatChip(
                    systemImage: model.isContinuing ? "bubble.left" : "square.and.pencil",
                    title: model.isContinuing ? "Continuing" : "New chat", menu: true, open: model.showsChooser,
                    height: 28, fontSize: 12.5)
            }
            ChatSendButton(
                size: 30, stops: model.isStreaming, tint: Color(hex: 0xD97757)
            ) {
                if model.isStreaming { model.stop() } else { model.send() }
            }
            .dmHelp(model.isStreaming ? "Stop" : "Send (Return)")
        }
        .padding(.horizontal, m.pt(14))
        .padding(.vertical, m.pt(12))
    }

    @ViewBuilder
    private var field: some View {
        let prompt = model.question == nil ? "Ask anything…" : "Ask a follow-up…"
        if let focused {
            TextField(prompt, text: $model.text)
                .textFieldStyle(.plain)
                .font(.dm(16))
                .focused(focused)
                .accessibilityLabel(prompt.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
                .accessibilityHint("Return sends, Command-Return opens the chat in Devmachine, Escape closes")
                .onSubmit { model.send() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        model.openCurrentInApp()
                        return .handled
                    }
                    return .ignored
                }
        } else {
            Text(verbatim: model.text.isEmpty ? prompt : model.text)
                .accessibilityLabel(prompt)
                .font(.dm(16))
                .foregroundStyle(model.text.isEmpty ? Color.dmMuted : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func answer(_ conversation: ChatConversation) -> some View {
        let last = conversation.messages.last { $0.role == .assistant } ?? ChatMessage(role: .assistant, text: "")
        let answering = conversation.messages.last?.role == .assistant ? last : ChatMessage(role: .assistant, text: "")
        return VStack(alignment: .leading, spacing: m.pt(10)) {
            Rectangle().fill(Color.dmDivider).frame(height: 1)
            HStack(spacing: m.pt(6)) {
                ChatHarnessGlyph(harness: model.shownHarness, size: 13)
                Text(verbatim: "\(ChatHarness.title(model.shownHarness)) on \(ChatPlaceLabel.title(model.shownPlace))")
                    .font(.dm(11, weight: .medium)).foregroundStyle(Color.dmMuted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: m.pt(10)) {
                    ChatAnswerView(message: answering, streaming: conversation.isStreaming, status: conversation.status)
                    if let failure = conversation.failure, let id = model.chatID {
                        ChatErrorCard(
                            failure: failure, chatID: id, harness: model.shownHarness, place: model.shownPlace,
                            compact: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: m.pt(420))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, m.pt(18))
        .padding(.bottom, m.pt(14))
    }

    private var chipsRow: some View {
        HStack(spacing: m.pt(6)) {
            ForEach([ChatPicker.harness, .workspace], id: \.self) { picker in
                ChatPickerChip(
                    picker: picker, harness: model.shownHarness, place: model.shownPlace, locked: model.isContinuing,
                    open: store.openPicker == picker, height: 28, fontSize: 12.5,
                    items: {
                        ChatPickerOverlay.items(
                            picker, store: store, harness: model.shownHarness, place: model.shownPlace,
                            pickHarness: { model.harness = $0 }, pickPlace: { model.place = $0 })
                    },
                    toggle: { store.openPicker = store.openPicker == picker ? nil : picker })
            }
            ChatMCPChip(isOn: model.usesMCP, height: 28, fontSize: 12.5) { model.toggleMCP() }
            Spacer()
            if model.question != nil {
                Text(verbatim: "Open in Devmachine ⌘↩  ·  Esc to close")
                    .font(.dm(11))
                    .foregroundStyle(Color.dmMuted)
                    .onTapGesture { model.openCurrentInApp() }
            } else if !hotkey.isEmpty {
                Text(verbatim: hotkey).font(.dm(11, design: .monospaced)).foregroundStyle(Color.dmMuted)
            }
        }
        .padding(.horizontal, m.pt(14))
        .padding(.vertical, m.pt(9))
        .background(Color.black.opacity(0.14))
        .clipShape(UnevenRoundedRectangle(
            bottomLeadingRadius: m.pt(DMRadius.bubble), bottomTrailingRadius: m.pt(DMRadius.bubble)))
    }
}
