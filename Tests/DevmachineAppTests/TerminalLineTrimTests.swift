import XCTest
import SwiftTerm
@testable import DevmachineApp

final class TerminalLineTrimTests: XCTestCase {
    private final class Quiet: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// A pane in the alternate screen (tmux) that was 80 columns wide drew a
    /// full line, then got 40 wide and drew a short line over it with an
    /// erase to the end. Nothing past column 40 is on screen; a copy of the
    /// row must not bring it back.
    func testACopyAfterANarrowerResizeStopsAtTheWidth() {
        let terminal = Terminal(delegate: Quiet(), options: TerminalOptions(cols: 80, rows: 5))
        terminal.feed(text: "\u{1b}[?1049h")
        terminal.feed(text: String(repeating: "x", count: 80))
        terminal.resize(cols: 40, rows: 5)
        terminal.feed(text: "\u{1b}[H" + "short" + "\u{1b}[K")
        XCTAssertTrue(terminal.isCurrentBufferAlternate)

        TerminalLineTrim.trim(terminal)

        let text = terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 0, row: 1))
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "short")
        XCTAssertEqual(terminal.getLine(row: 0)?.count, 40)
    }

    func testTheNormalScreenIsLeftAsItIs() {
        let terminal = Terminal(delegate: Quiet(), options: TerminalOptions(cols: 80, rows: 5))
        terminal.feed(text: String(repeating: "y", count: 80))
        terminal.resize(cols: 40, rows: 5)
        TerminalLineTrim.trim(terminal)
        XCTAssertEqual(terminal.getLine(row: 0)?.count, 40)
        XCTAssertFalse(terminal.isCurrentBufferAlternate)
    }

    /// The pinned SwiftTerm has no public way from a view to its `Terminal`;
    /// the trim reads the view's stored property by reflection. A bump that
    /// renames it would make this fail, not the copy in the running app.
    @MainActor
    func testTheTerminalBehindAViewIsFound() {
        let view = SelectingTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertNotNil(TerminalLineTrim.terminal(behind: view))
    }
}
