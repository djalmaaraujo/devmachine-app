import XCTest
import AppKit
@testable import DevmachineApp

/// The toolbar band over the window's top keeps dragging the window except
/// where a view claims the spot; a terminal claims all of itself, so its top
/// lines select text instead of moving the window.
@MainActor
final class TerminalTitlebarClickTests: XCTestCase {
    private typealias OpaqueRect = @convention(c) (AnyObject, Selector) -> NSRect
    private let selector = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")

    private func claimedRect(_ view: NSView) -> NSRect {
        unsafeBitCast(class_getMethodImplementation(type(of: view), selector), to: OpaqueRect.self)(view, selector)
    }

    func testAppKitStillAsksEveryViewWhichPartOfTheBandItClaims() {
        XCTAssertTrue(NSView.instancesRespond(to: selector))
        XCTAssertEqual(claimedRect(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))), .zero)
    }

    func testATerminalClaimsAllOfItself() {
        let view = SelectingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertEqual(claimedRect(view), view.bounds)
    }
}
