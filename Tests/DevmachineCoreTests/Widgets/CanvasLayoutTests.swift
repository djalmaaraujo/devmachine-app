import XCTest
@testable import DevmachineCore

final class CanvasLayoutTests: XCTestCase {
    private func frame(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> BoardFrame { BoardFrame(x: x, y: y, w: w, h: h) }

    private func medium(_ x: Int, _ y: Int) -> BoardFrame { frame(x, y, 320, 160) }

    func testSnapRoundsToTheNearestEightPoints() {
        XCTAssertEqual(CanvasLayout.snapped(0), 0)
        XCTAssertEqual(CanvasLayout.snapped(3.9), 0)
        XCTAssertEqual(CanvasLayout.snapped(4), 8)
        XCTAssertEqual(CanvasLayout.snapped(13), 16)
        XCTAssertEqual(CanvasLayout.snapped(-3), 0)
    }

    func testPresetsAreUnitsOfEightyPoints() {
        XCTAssertEqual(CanvasLayout.presetSize("small"), CanvasSize(w: 160, h: 160))
        XCTAssertEqual(CanvasLayout.presetSize("medium"), CanvasSize(w: 320, h: 160))
        XCTAssertEqual(CanvasLayout.presetSize("large"), CanvasSize(w: 320, h: 320))
        XCTAssertEqual(CanvasLayout.presetSize("wide"), CanvasSize(w: 640, h: 160))
        XCTAssertEqual(CanvasLayout.presetSize("tall"), CanvasSize(w: 160, h: 320))
        XCTAssertNil(CanvasLayout.presetSize("custom"))
    }

    func testTheMinimumKeepsEveryAcceptedPresetReachable() {
        XCTAssertEqual(CanvasLayout.minimumSize(sizes: ["small", "medium", "wide"]), CanvasSize(w: 160, h: 160))
        XCTAssertEqual(CanvasLayout.minimumSize(sizes: ["wide", "tall"]), CanvasSize(w: 160, h: 160))
        XCTAssertEqual(CanvasLayout.minimumSize(sizes: ["large"]), CanvasSize(w: 320, h: 320))
        XCTAssertEqual(CanvasLayout.minimumSize(sizes: ["wide"]), CanvasSize(w: 640, h: 160))
        XCTAssertEqual(CanvasLayout.minimumSize(sizes: []), CanvasSize(w: 160, h: 160))
    }

    func testASizeIsNamedOnlyWhenItIsAnAcceptedPreset() {
        XCTAssertEqual(CanvasLayout.sizeName(CanvasSize(w: 320, h: 160), sizes: ["small", "medium"]), "medium")
        XCTAssertEqual(CanvasLayout.sizeName(CanvasSize(w: 328, h: 160), sizes: ["small", "medium"]), "custom")
        XCTAssertEqual(CanvasLayout.sizeName(CanvasSize(w: 640, h: 160), sizes: ["small", "medium"]), "custom")
    }

    func testResizeSnapsAndNeverGoesUnderTheMinimum() {
        let start = frame(24, 24, 320, 160)
        let minimum = CanvasSize(w: 160, h: 160)
        XCTAssertEqual(CanvasLayout.resized(start, width: 333, height: 171, minimum: minimum), frame(24, 24, 336, 168))
        XCTAssertEqual(CanvasLayout.resized(start, width: 40, height: 10, minimum: minimum), frame(24, 24, 160, 160))
    }

    func testClampMovesTheDrawingOnScreenOnly() {
        let stored = frame(1200, 900, 320, 160)
        let drawn = CanvasLayout.clamped(stored, in: CGSize(width: 1000, height: 700))
        XCTAssertEqual(drawn, CGRect(x: 680, y: 540, width: 320, height: 160))
        XCTAssertEqual(stored, frame(1200, 900, 320, 160))
        let wider = CanvasLayout.clamped(frame(100, 0, 1200, 160), in: CGSize(width: 1000, height: 700))
        XCTAssertEqual(wider.minX, 0)
    }

    func testAMoveWithNothingNearSnapsToTheGrid() {
        let move = CanvasLayout.moved(frame(0, 0, 160, 160), to: CGPoint(x: 101, y: 53), among: [])
        XCTAssertEqual(move.frame, frame(104, 56, 160, 160))
        XCTAssertEqual(move.guides, [])
    }

    func testAnEdgeWithinSixPointsSnapsToTheOtherWidgetsEdge() {
        let other = frame(200, 400, 320, 160)
        let move = CanvasLayout.moved(frame(0, 0, 160, 160), to: CGPoint(x: 204.5, y: 37), among: [other])
        XCTAssertEqual(move.frame.x, 200)
        XCTAssertEqual(move.frame.y, 40)
        XCTAssertEqual(move.guides, [CanvasGuide(axis: .vertical, position: 200, start: 40, end: 560)])
    }

    func testCentresAlignToo() {
        let other = frame(0, 0, 320, 160)
        let move = CanvasLayout.moved(frame(0, 0, 160, 160), to: CGPoint(x: 83, y: 400), among: [other])
        XCTAssertEqual(move.frame.x, 80)
        XCTAssertEqual(move.guides.first?.axis, .vertical)
        XCTAssertEqual(move.guides.first?.position, 160)
    }

    func testAnEdgeNeverSnapsToAnotherWidgetsCentre() {
        let panel = frame(728, 0, 1504, 400)
        let move = CanvasLayout.moved(frame(1096, 1072, 384, 232), to: CGPoint(x: 1098, y: 1072), among: [panel])
        XCTAssertEqual(move.guides, [])
        XCTAssertEqual(move.frame.x, 1096)
    }

    func testACentreNeverSnapsToAnotherWidgetsEdge() {
        let other = frame(400, 0, 320, 160)
        let move = CanvasLayout.moved(frame(0, 600, 160, 160), to: CGPoint(x: 323, y: 600), among: [other])
        XCTAssertEqual(move.guides, [])
        XCTAssertEqual(move.frame.x, 320)
    }

    func testACentreGuideSaysItIsACentre() {
        let other = frame(0, 0, 320, 160)
        let move = CanvasLayout.moved(frame(0, 0, 160, 160), to: CGPoint(x: 83, y: 400), among: [other])
        XCTAssertEqual(move.guides, [CanvasGuide(axis: .vertical, position: 160, start: 0, end: 560, kind: .centre)])
    }

    func testAnEdgeGuideSaysItIsAnEdge() {
        let other = frame(200, 400, 320, 160)
        let move = CanvasLayout.moved(frame(0, 0, 160, 160), to: CGPoint(x: 204.5, y: 37), among: [other])
        XCTAssertEqual(move.guides.map(\.kind), [.edge])
    }

    func testOnlyWidgetsDrawnOnScreenAreSnapTargets() {
        let widgets = ["clock", "machines", "unresolved"].map {
            BoardWidget(id: $0, type: "devmachine-app/\($0)", frame: frame(0, 0, 160, 160), size: "small", z: 1)
        }
        let targets = CanvasLayout.snapTargets(widgets, moving: "clock") { $0.id != "unresolved" }
        XCTAssertEqual(targets.map(\.id), ["machines"])
    }

    func testAMoveNeverLeavesTheCanvasOrigin() {
        let move = CanvasLayout.moved(frame(0, 0, 160, 160), to: CGPoint(x: -50, y: -9), among: [])
        XCTAssertEqual(move.frame.x, 0)
        XCTAssertEqual(move.frame.y, 0)
    }

    func testTheFirstFreeSpotKeepsEightPointsFromEveryOtherWidget() {
        let size = CanvasSize(w: 320, h: 160)
        XCTAssertEqual(CanvasLayout.firstFreeSpot(for: size, avoiding: []), medium(24, 24))
        XCTAssertEqual(CanvasLayout.firstFreeSpot(for: size, avoiding: [medium(24, 24)]), medium(352, 24))
        XCTAssertEqual(
            CanvasLayout.firstFreeSpot(for: size, avoiding: [medium(24, 24), medium(1008, 24)]), medium(352, 24))
        XCTAssertEqual(
            CanvasLayout.firstFreeSpot(
                for: size, avoiding: [medium(24, 24), medium(352, 24), medium(680, 24), medium(1008, 24)]),
            medium(24, 192))
    }

    func testTheFirstFreeSpotWrapsWhenTheBandIsNarrow() {
        let spot = CanvasLayout.firstFreeSpot(for: CanvasSize(w: 320, h: 160), avoiding: [medium(24, 24)], bandWidth: 400)
        XCTAssertEqual(spot, medium(24, 192))
    }

    func testAWidgetWiderThanTheBandStillGoesAtTheMargin() {
        let spot = CanvasLayout.firstFreeSpot(for: CanvasSize(w: 2000, h: 160), avoiding: [])
        XCTAssertEqual(spot, frame(24, 24, 2000, 160))
    }

    func testDisplayScaleNeverReachesTheStoredFrame() {
        let scale = 1.3
        let drawn = CanvasLayout.toDisplay(frame(24, 24, 320, 160).rect, scale: scale)
        XCTAssertEqual(drawn.width, 416, accuracy: 0.001)
        let translation = CanvasLayout.toBoard(CGSize(width: 104, height: 52), scale: scale)
        let start = frame(24, 24, 320, 160)
        let move = CanvasLayout.moved(
            start, to: CGPoint(x: Double(start.x) + translation.width, y: Double(start.y) + translation.height), among: [])
        XCTAssertEqual(move.frame, frame(104, 64, 320, 160))
    }

    func testTheDraggedWidgetIsLiftedAboveEveryOtherWithoutChangingTheBoard() {
        let board = Board(surface: "home", widgets: [
            BoardWidget(id: "clock", type: "devmachine-app/clock", frame: medium(368, 24), size: "medium", z: 1),
            BoardWidget(id: "machines", type: "devmachine-app/machines", frame: frame(24, 24, 320, 320), size: "large", z: 3),
            BoardWidget(id: "codex-usage", type: "codex/usage", frame: medium(24, 360), size: "medium", z: 5),
        ])
        let levels = board.widgets.map { CanvasLayout.stackLevel(of: $0, in: board, lifting: "machines") }

        XCTAssertEqual(levels, [1, 6, 5])
        XCTAssertEqual(board.widgets.map(\.z), [1, 3, 5])
    }

    func testWithoutADragEveryWidgetStacksAtItsOwnZ() {
        let board = Board(surface: "home", widgets: [
            BoardWidget(id: "clock", type: "devmachine-app/clock", frame: medium(368, 24), size: "medium", z: 2),
            BoardWidget(id: "summary", type: "devmachine-app/summary", frame: medium(368, 200), size: "medium", z: 1),
        ])

        XCTAssertEqual(board.widgets.map { CanvasLayout.stackLevel(of: $0, in: board, lifting: nil) }, [2, 1])
    }

    private func rect(_ x: Double, _ w: Double, y: Double = 0, h: Double = 100) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    func testAWidgetKeepsItsCentreInProportionWhenTheCanvasWidens() {
        let xs = CanvasLayout.aligned(["clock": rect(350, 300)], from: 1000, to: 1200)
        XCTAssertEqual(xs["clock"], 450)
    }

    func testAWidgetAtAnEdgeStaysAtThatEdge() {
        let xs = CanvasLayout.aligned(
            ["left": rect(24, 200), "right": rect(756, 220)], from: 1000, to: 1200)
        XCTAssertEqual(xs["left"], 24)
        XCTAssertEqual(xs["right"], 956)
    }

    func testWidgetsThatTouchMoveTogetherAndKeepTheirGaps() {
        let xs = CanvasLayout.aligned(
            ["a": rect(300, 128), "b": rect(436, 128), "c": rect(572, 128), "far": rect(300, 128, y: 400)],
            from: 1000, to: 1200)
        XCTAssertEqual(xs["a"], 400)
        XCTAssertEqual(xs["b"], 536)
        XCTAssertEqual(xs["c"], 672)
        XCTAssertEqual(xs["far"] ?? 0, 366.99, accuracy: 0.01)
    }

    func testAWidgetJustPastTheMarginStaysInsideIt() {
        let xs = CanvasLayout.aligned(["a": rect(30, 200)], from: 1200, to: 1000)
        XCTAssertGreaterThan(xs["a"] ?? 0, 24)
        XCTAssertLessThan(xs["a"] ?? 0, 30)
    }

    func testAligningBackGivesTheStoredPlaces() {
        let stored = [
            "edge": rect(24, 200), "near": rect(30, 160, y: 400), "clock": rect(350, 300, y: 200),
            "a": rect(300, 128, y: 600), "b": rect(436, 128, y: 600), "usage": rect(756, 220),
        ]
        var drawn = stored
        for (id, x) in CanvasLayout.aligned(stored, from: 1000, to: 1200) { drawn[id]?.origin.x = x }
        let back = CanvasLayout.aligned(drawn, from: 1200, to: 1000)
        for (id, frame) in stored { XCTAssertEqual(back[id] ?? -1, frame.minX, accuracy: 0.001, id) }
    }

    func testAWidgetDroppedBesideAGroupKeepsItsGapAfterTheRoundTrip() {
        let stored = ["a": rect(300, 128), "b": rect(436, 128)]
        var drawn = stored
        for (id, x) in CanvasLayout.aligned(stored, from: 1000, to: 1200) { drawn[id]?.origin.x = x }
        drawn["c"] = rect(drawn["b"]!.maxX + 8, 128)
        var next = drawn
        for (id, x) in CanvasLayout.aligned(drawn, from: 1200, to: 1000) { next[id]?.origin.x = x }
        let shown = CanvasLayout.aligned(next, from: 1000, to: 1200)
        for id in ["a", "b", "c"] { XCTAssertEqual(shown[id] ?? -1, drawn[id]!.minX, accuracy: 0.001, id) }
    }

    func testAGroupWiderThanEitherCanvasStaysPut() {
        XCTAssertEqual(CanvasLayout.aligned(["wide": rect(100, 900)], from: 1200, to: 900), ["wide": 100])
        XCTAssertEqual(CanvasLayout.aligned(["wide": rect(100, 900)], from: 900, to: 1200), ["wide": 100])
    }

    func testTheSameWidthMovesNothing() {
        let stored = ["a": rect(333, 100)]
        XCTAssertEqual(CanvasLayout.aligned(stored, from: 1000, to: 1000), ["a": 333])
        XCTAssertEqual(CanvasLayout.aligned(stored, from: 0, to: 1000), ["a": 333])
    }
}
