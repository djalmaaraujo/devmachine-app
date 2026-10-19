import XCTest
import SwiftUI
import AppKit
@testable import DevmachineApp

@MainActor
final class BelowTitlebarPaneTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private final class Probe: NSView {}

    private struct ProbeView: NSViewRepresentable {
        let probe: Probe
        func makeNSView(context: Context) -> Probe { probe }
        func updateNSView(_ view: Probe, context: Context) {}
    }

    private func host<V: View>(_ root: V) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "band")
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: root.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.layoutIfNeeded()
        self.window = window
        return window.contentView!.superview!
    }

    private func hit(_ frameView: NSView, y: CGFloat) -> NSView? {
        let point = NSPoint(x: 400, y: frameView.isFlipped ? y : frameView.bounds.height - y)
        return frameView.hitTest(point)
    }

    private func distanceFromTop(_ view: NSView, in frameView: NSView) -> CGFloat {
        let rect = view.convert(view.bounds, to: frameView)
        return frameView.isFlipped ? rect.minY : frameView.bounds.height - rect.maxY
    }

    func testTheToolbarBandTakesEveryClickAcrossTheWindowTop() {
        let probe = Probe()
        let frameView = host(ProbeView(probe: probe).ignoresSafeArea(edges: .top))
        XCTAssertFalse(hit(frameView, y: 20) === probe)
    }

    func testTheContentStartsBelowTheBandSoItsTopLineTakesClicks() throws {
        let probe = Probe()
        let frameView = host(BelowTitlebarPane {
            Color.red
        } content: {
            ProbeView(probe: probe)
        })
        let band = try XCTUnwrap(window?.contentView?.safeAreaInsets.top)
        XCTAssertGreaterThan(band, 0)
        XCTAssertEqual(distanceFromTop(probe, in: frameView), band, accuracy: 0.5)
        XCTAssertTrue(hit(frameView, y: band + 1) === probe)
    }

    func testTheBackgroundStillReachesTheWindowTop() throws {
        let probe = Probe()
        let frameView = host(BelowTitlebarPane {
            ProbeView(probe: probe)
        } content: {
            Color.clear.allowsHitTesting(false)
        })
        XCTAssertEqual(distanceFromTop(probe, in: frameView), 0, accuracy: 0.5)
    }
}
