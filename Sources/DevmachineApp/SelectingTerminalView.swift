import AppKit
import SwiftTerm
import DevmachineCore

/// A terminal whose selection is its own in every session (`TerminalPointer`).
/// SwiftTerm gives every press, drag and release to a program that asked for
/// the mouse, and tmux asks for it in every remote session: a drag then became
/// tmux's own yellow selection, a click could not clear a selection made
/// before, and the copy depended on a chain of settings on the host. Here the
/// three always go to SwiftTerm's selection first, a plain click is handed to
/// the program afterwards, and the wheel keeps SwiftTerm's rule, so tmux
/// still scrolls its history.
class SelectingTerminalView: LocalProcessTerminalView {
    /// The zsh package gives tmux's copy mode this colour too (`mode-style`).
    static let selectionColor = NSColor(srgbRed: 0, green: 0xA6 / 255, blue: 0xB2 / 255, alpha: 1)

    var copiesOnSelect: () -> Bool = { true }
    var pasteboard: NSPasteboard = .general
    lazy var paneIsFocused: () -> Bool = { [unowned self] in
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    private var delegateGate: TerminalDelegateGate?
    private var press: NSEvent?
    private var dragged = false
    private var replayingClick = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        selectedTextBackgroundColor = Self.selectionColor
        let gate = TerminalDelegateGate(view: self)
        delegateGate = gate
        terminalDelegate = gate
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The terminal runs up under the see-through toolbar band, and the window
    /// server drags the window from any part of the band no view claims,
    /// before the app sees the click. AppKit has no public way to claim it;
    /// NSButton claims its bounds through this same private method.
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect {
        bounds
    }

    override func mouseDown(with event: NSEvent) {
        press = event
        dragged = false
        selecting { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        if !dragged {
            guard TerminalPointer.isDrag(from: press.locationInWindow, to: event.locationInWindow) else { return }
            dragged = true
            // SwiftTerm anchors a selection at the first drag event; this one
            // sits where the button went down, so the first letters are kept.
            if let anchor = NSEvent.mouseEvent(
                with: .leftMouseDragged, location: press.locationInWindow, modifierFlags: press.modifierFlags,
                timestamp: press.timestamp, windowNumber: press.windowNumber, context: nil,
                eventNumber: press.eventNumber, clickCount: press.clickCount, pressure: press.pressure) {
                selecting { super.mouseDragged(with: anchor) }
            }
        }
        selecting { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragged = dragged
        let pressed = press
        press = nil
        dragged = false
        selecting { super.mouseUp(with: event) }
        if TerminalPointer.copiesOnRelease(
            enabled: copiesOnSelect(), dragged: wasDragged, clickCount: event.clickCount,
            hasSelection: selectionActive) {
            copySelection()
        }
        let gesture = TerminalPointer.Gesture.release(
            dragged: wasDragged, clickCount: event.clickCount, command: event.modifierFlags.contains(.command))
        if TerminalPointer.route(gesture) == .selectionThenProgram, let pressed {
            replayClick(press: pressed, release: event)
        }
    }

    /// ⌘C and the context menu. With nothing selected the clipboard keeps
    /// what it has; SwiftTerm's own copy would empty it.
    override func copy(_ sender: Any) {
        copySelection()
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard !replayingClick else { return }
        openRequestedLink(link, params: params)
    }

    func openRequestedLink(_ link: String, params: [String: String]) {
        super.requestOpenLink(source: self, link: link, params: params)
    }

    func writeToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copySelection() {
        guard let text = getSelection(), !text.isEmpty else { return }
        writeToClipboard(text)
    }

    private func selecting(_ body: () -> Void) {
        let reporting = allowMouseReporting
        allowMouseReporting = false
        defer { allowMouseReporting = reporting }
        body()
    }

    /// SwiftTerm sends the click to the program only when the program reads
    /// the mouse; otherwise the second pass finds nothing left to do.
    private func replayClick(press: NSEvent, release: NSEvent) {
        replayingClick = true
        defer { replayingClick = false }
        super.mouseDown(with: press)
        super.mouseUp(with: release)
    }
}

/// Stands between SwiftTerm and the pane for everything the terminal asks of
/// its host. `LocalProcessTerminalView` answers the clipboard itself and does
/// not let a subclass change that: it takes any OSC 52 write, from any pane,
/// and hands the Mac's clipboard to any program that queries it. Every other
/// request goes to the pane unchanged.
@MainActor
final class TerminalDelegateGate: @preconcurrency TerminalViewDelegate {
    private unowned let view: SelectingTerminalView

    init(view: SelectingTerminalView) {
        self.view = view
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = TerminalClipboard.text(fromWrite: content, paneIsFocused: view.paneIsFocused()) else {
            return
        }
        view.writeToClipboard(text)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        nil
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        view.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view.scrolled(source: source, position: position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        view.requestOpenLink(source: source, link: link, params: params)
    }

    func bell(source: TerminalView) {
        view.bell(source: source)
    }

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        view.kittyClipboardCapabilities(source: source)
    }

    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? {
        view.kittyClipboardAvailableMimeTypes(source: source, location: location)
    }

    func kittyClipboardRead(
        source: TerminalView, location: KittyClipboardLocation, mimeType: String
    ) -> KittyClipboardReadResult? {
        view.kittyClipboardRead(source: source, location: location, mimeType: mimeType)
    }

    func kittyClipboardWrite(
        source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult {
        view.kittyClipboardWrite(source: source, location: location, content: content)
    }

    func kittyClipboardRequestPermission(
        source: TerminalView, request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult {
        view.kittyClipboardRequestPermission(source: source, request: request)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        view.iTermContent(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view.rangeChanged(source: source, startY: startY, endY: endY)
    }
}
