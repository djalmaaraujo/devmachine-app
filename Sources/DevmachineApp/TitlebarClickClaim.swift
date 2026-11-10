import SwiftUI
import AppKit

/// Claims the spot it covers in the see-through toolbar band, so a click there
/// reaches the SwiftUI view above it instead of moving the window. The window
/// server drags the window from any part of the band no view claims, before
/// the app sees the click, and a SwiftUI view claims nothing on its own: a tab
/// chip laid under the band never got its tap. Put it behind a control with
/// `.claimsTitlebarClicks()`; the empty band around it still drags.
struct TitlebarClickClaim: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarClaimView { TitlebarClaimView() }
    func updateNSView(_ nsView: TitlebarClaimView, context: Context) {}
}

/// Invisible and out of hit-testing, so the click goes on to SwiftUI; it only
/// answers AppKit's question about which part of the band it holds.
final class TitlebarClaimView: NSView {
    /// AppKit has no public way to claim part of the band; NSButton claims its
    /// bounds through this same private method (`SelectingTerminalView` too).
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect {
        bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

extension View {
    /// Keeps a click on this view from moving the window while it sits under
    /// the toolbar band (`TitlebarClickClaim`).
    func claimsTitlebarClicks() -> some View {
        background(TitlebarClickClaim())
    }
}
