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

/// A control under the band takes its click through an AppKit target that
/// claims its spot and runs the action itself on release.
@MainActor
final class TitlebarClickTargetTests: XCTestCase {
    private typealias OpaqueRect = @convention(c) (AnyObject, Selector) -> NSRect
    private let selector = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")

    func testTheTargetClaimsAllOfItselfAndNeverMovesTheWindow() {
        let view = TitlebarClickTargetView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        let claimed = unsafeBitCast(
            class_getMethodImplementation(type(of: view), selector), to: OpaqueRect.self)(view, selector)
        XCTAssertEqual(claimed, view.bounds)
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertTrue(view.hitTest(NSPoint(x: 10, y: 10)) === view)
    }

    func testARightClickOffersTheMenuItems() {
        let view = TitlebarClickTargetView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        var closed = false
        view.menuItems = [("Close", { closed = true })]
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = view.menu(for: event)
        XCTAssertEqual(menu?.items.map(\.title), ["Close"])
        _ = menu?.items.first.flatMap { item in (item.target as? NSObject)?.perform(item.action) }
        XCTAssertTrue(closed)
    }

    func testTheRouterHandsAPressInsideATargetToItAndRunsTheActionOnRelease() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let chip = TitlebarClickTargetView(frame: NSRect(x: 10, y: 60, width: 120, height: 30))
        let close = TitlebarClickTargetView(frame: NSRect(x: 100, y: 65, width: 20, height: 20))
        var ran: [String] = []
        chip.action = { ran.append("select") }
        close.action = { ran.append("close") }
        window.contentView?.addSubview(chip)
        window.contentView?.addSubview(close)

        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        let router = TitlebarClickRouter.shared
        XCTAssertTrue(router.route(event(.leftMouseDown, NSPoint(x: 30, y: 70))))
        XCTAssertTrue(router.route(event(.leftMouseUp, NSPoint(x: 30, y: 70))))
        // The close mark sits over the chip's edge: the smaller target wins.
        XCTAssertTrue(router.route(event(.leftMouseDown, NSPoint(x: 110, y: 75))))
        XCTAssertTrue(router.route(event(.leftMouseUp, NSPoint(x: 110, y: 75))))
        // Outside every target the click goes on as usual.
        XCTAssertFalse(router.route(event(.leftMouseDown, NSPoint(x: 250, y: 20))))
        XCTAssertFalse(router.route(event(.leftMouseUp, NSPoint(x: 250, y: 20))))
        XCTAssertEqual(ran, ["select", "close"])
    }
}
