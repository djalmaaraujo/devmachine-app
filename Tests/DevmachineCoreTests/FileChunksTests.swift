import XCTest
import Foundation
@testable import DevmachineCore

final class FileChunksTests: XCTestCase {
    func testLinesComeInPiecesNumberedFromOne() {
        let chunks = FileChunks.lines("a\nb\nc\nd\ne\n", perChunk: 2)
        XCTAssertEqual(chunks.map(\.firstLine), [1, 3, 5])
        XCTAssertEqual(chunks.map(\.text), ["a\nb", "c\nd", "e"])
        XCTAssertEqual(chunks.last?.lastLine, 5)
        XCTAssertEqual(FileChunks.lines("").map(\.lines), [[""]], "an empty file is one empty line")
        XCTAssertEqual(FileChunks.lines("a\n\nb").map(\.lines), [["a", "", "b"]], "a blank line in the middle stays")
    }

    func testTheLongestLineIsMeasuredInCharacters() {
        XCTAssertEqual(FileChunks.longestLine("ab\nçãé\n"), 3)
        XCTAssertEqual(FileChunks.longestLine(""), 0)
    }

    func testMarkdownUnderTheTargetComesBackWhole() {
        let text = "# Title\n\nSome text.\n"
        XCTAssertEqual(FileChunks.markdown(text, targetBytes: 100), [text])
    }

    func testMarkdownIsCutAtABlankLineOutsideAFence() {
        let text = """
        # One

        para one

        ```swift
        let a = 1

        let b = 2
        ```

        para two

        para three
        """
        let pieces = FileChunks.markdown(text, targetBytes: 8)
        XCTAssertEqual(pieces, [
            "# One\n\npara one",
            "```swift\nlet a = 1\n\nlet b = 2\n```",
            "para two",
            "para three",
        ])
        XCTAssertEqual(pieces.joined(separator: "\n\n"), text, "nothing is lost")
    }

    func testMarkdownPiecesRepeatTheReferenceDefinitions() {
        let text = "see [the docs][docs] " + String(repeating: "x", count: 30) + "\n\nmore [docs]\n\n[docs]: https://example.com/docs\n"
        let pieces = FileChunks.markdown(text, targetBytes: 10)
        XCTAssertEqual(pieces.count, 3)
        for piece in pieces {
            XCTAssertTrue(piece.contains("[docs]: https://example.com/docs"), piece)
        }
        XCTAssertEqual(pieces[2], "[docs]: https://example.com/docs\n", "the definition's own piece is not doubled")
    }

    func testFencesWithTildesAndLongerClosersAreTracked() {
        XCTAssertNotNil(FileChunks.opensFence("~~~"))
        XCTAssertNotNil(FileChunks.opensFence("   ````swift"))
        XCTAssertNil(FileChunks.opensFence("    ```"), "four spaces is an indented code block")
        XCTAssertNil(FileChunks.opensFence("``` not a `fence`"))
        XCTAssertTrue(FileChunks.closesFence("`````", ("`", 4)))
        XCTAssertFalse(FileChunks.closesFence("```", ("`", 4)))
        XCTAssertFalse(FileChunks.closesFence("``` x", ("`", 3)))
        XCTAssertTrue(FileChunks.isReferenceDefinition("[a]: https://x"))
        XCTAssertFalse(FileChunks.isReferenceDefinition("[a]:"))
        XCTAssertFalse(FileChunks.isReferenceDefinition("[a] text"))
    }

    func testAHighlightedCopyIsCutIntoTheSamePieces() {
        var attributed = AttributedString("one\ntwo\nthree\n")
        attributed.foregroundColor = .red
        let chunks = FileChunks.lines("one\ntwo\nthree\n", perChunk: 2)
        let pieces = try! XCTUnwrap(AttributedLines.split(attributed, into: chunks))
        XCTAssertEqual(pieces.keys.sorted(), [1, 3])
        XCTAssertEqual(String(pieces[1]!.characters), "one\ntwo")
        XCTAssertEqual(String(pieces[3]!.characters), "three")
        XCTAssertNil(AttributedLines.split(AttributedString("one\nthree"), into: chunks), "fewer lines with text is refused")
    }

    func testBlankLinesTheHighlighterDroppedAtTheEndComeBack() throws {
        let plain = "one\ntwo\n\n\n"
        let chunks = FileChunks.lines(plain, perChunk: 2)
        XCTAssertEqual(chunks.map(\.lines), [["one", "two"], ["", ""]])
        let pieces = try XCTUnwrap(AttributedLines.split(AttributedString("one\ntwo"), into: chunks))
        XCTAssertEqual(String(pieces[1]!.characters), "one\ntwo")
        XCTAssertEqual(String(pieces[3]!.characters), "\n", "two blank lines, so the numbers beside them line up")

        let three = FileChunks.lines("a\nb\nc\n\n", perChunk: 3)
        XCTAssertEqual(three.map(\.lines), [["a", "b", "c"], [""]])
        let cut = try XCTUnwrap(AttributedLines.split(AttributedString("a\nb\nc"), into: three))
        XCTAssertEqual(String(cut[4]!.characters), "")
        let mid = FileChunks.lines("a\nb\n\n", perChunk: 2)
        let short = try XCTUnwrap(AttributedLines.split(AttributedString("a\nb"), into: mid))
        XCTAssertEqual(String(short[1]!.characters), "a\nb")
        XCTAssertEqual(String(short[3]!.characters), "")
        XCTAssertNil(AttributedLines.split(AttributedString("a"), into: mid), "a dropped line with text is refused")
    }
}
