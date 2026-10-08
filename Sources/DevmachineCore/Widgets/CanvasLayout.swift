import CoreGraphics
import Foundation

public struct CanvasSize: Equatable, Sendable {
    public let w: Int
    public let h: Int

    public init(w: Int, h: Int) {
        self.w = w
        self.h = h
    }
}

/// A line drawn while dragging, where an edge or centre lines up with
/// another widget's.
public struct CanvasGuide: Equatable, Sendable {
    public enum Axis: Equatable, Sendable { case vertical, horizontal }
    public enum Kind: Equatable, Sendable { case edge, centre }

    public let axis: Axis
    public let position: Double
    public let start: Double
    public let end: Double
    public let kind: Kind

    public init(axis: Axis, position: Double, start: Double, end: Double, kind: Kind = .edge) {
        self.axis = axis
        self.position = position
        self.start = start
        self.end = end
        self.kind = kind
    }
}

public struct CanvasMove: Equatable, Sendable {
    public let frame: BoardFrame
    public let guides: [CanvasGuide]
}

public struct CanvasPlacement: Equatable, Sendable {
    public let id: String
    public let x: Int
    public let y: Int
    public let w: Int
    public let h: Int

    public init(id: String, x: Int, y: Int, w: Int, h: Int) {
        self.id = id
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct CanvasResize: Equatable, Sendable {
    public let frame: BoardFrame
    public let auto: Bool
}

/// Canvas geometry in board points (100% text size). The view multiplies by
/// the text scale to draw and divides to store, so the file never depends
/// on Settings.
public enum CanvasLayout {
    public static let snap = 8
    public static let guideTolerance = 6.0
    public static let margin = 24
    /// Same gap and band as the CLI's `widgets add`, so both place a new
    /// widget on the same spot.
    public static let gap = 8
    public static let bandWidth = 1280

    public static func snapped(_ value: Double) -> Int {
        let steps = (value / Double(snap)).rounded()
        return max(0, Int(steps) * snap)
    }

    public static func presetSize(_ name: String, contract: WidgetContract = .current) -> CanvasSize? {
        guard let cells = contract.presetCells(name) else { return nil }
        return CanvasSize(w: cells.columns * contract.unit, h: cells.rows * contract.unit)
    }

    public static func minimumSize(
        sizes: [String], grows: Bool = false, contract: WidgetContract = .current
    ) -> CanvasSize {
        let all = sizes.compactMap { presetSize($0, contract: contract) }
        let fallback = presetSize("small", contract: contract) ?? CanvasSize(w: 160, h: 160)
        guard let width = all.map(\.w).min(), let height = all.map(\.h).min() else {
            return grows ? CanvasSize(w: fallback.w, h: contract.stackRow) : fallback
        }
        return CanvasSize(w: width, h: grows ? contract.stackRow : height)
    }

    public static func drawnHeight(
        of widget: BoardWidget, content: Int?, grows: Bool, contract: WidgetContract = .current
    ) -> Int {
        guard grows else { return widget.frame.h }
        if widget.isAuto { return content ?? contract.stackRow }
        let cap = max(widget.frame.h, contract.stackRow)
        return content.map { min($0, cap) } ?? cap
    }

    public static func placement(
        of widget: BoardWidget, content: Int?, grows: Bool, contract: WidgetContract = .current
    ) -> CanvasPlacement {
        CanvasPlacement(
            id: widget.id, x: widget.frame.x, y: widget.frame.y, w: widget.frame.w,
            h: drawnHeight(of: widget, content: content, grows: grows, contract: contract))
    }

    /// The height the person dragged to, cut at the content. Within one snap
    /// of the content the widget goes back to `auto`, so a drag to "as tall as
    /// it is" does not freeze a height the content will outgrow.
    public static func resizedGrowing(
        _ frame: BoardFrame, width: Double, height: Double, content: Int, minimum: CanvasSize
    ) -> CanvasResize {
        let dragged = max(minimum.h, snapped(height))
        let drawn = min(dragged, content)
        let auto = content - drawn <= snap
        let next = BoardFrame(x: frame.x, y: frame.y, w: max(minimum.w, snapped(width)), h: auto ? content : drawn)
        return CanvasResize(frame: next, auto: auto)
    }

    public static func pushedDown(_ items: [CanvasPlacement]) -> [String: Int] {
        let ordered = items.enumerated().sorted { a, b in
            (a.element.y, a.element.x, a.offset) < (b.element.y, b.element.x, b.offset)
        }.map(\.element)
        var drawnY: [String: Int] = [:]
        var above: [CanvasPlacement] = []
        for item in ordered {
            var y = item.y
            for earlier in above where earlier.x < item.x + item.w && item.x < earlier.x + earlier.w {
                y = max(y, (drawnY[earlier.id] ?? earlier.y) + earlier.h + gap)
            }
            drawnY[item.id] = y
            above.append(item)
        }
        return drawnY
    }

    public static func reset(
        _ widget: BoardWidget, defaultSize: String, grows: Bool, contract: WidgetContract = .current
    ) -> BoardWidget {
        var next = widget
        let preset = presetSize(defaultSize, contract: contract)
        if grows {
            next.size = BoardWidget.autoSize
            next.frame = BoardFrame(x: widget.frame.x, y: widget.frame.y, w: preset?.w ?? widget.frame.w, h: 0)
        } else if let preset {
            next.size = defaultSize
            next.frame = BoardFrame(x: widget.frame.x, y: widget.frame.y, w: preset.w, h: preset.h)
        }
        return next
    }

    public static func sizeName(_ size: CanvasSize, sizes: [String], contract: WidgetContract = .current) -> String {
        sizes.first { presetSize($0, contract: contract) == size } ?? BoardWidget.customSize
    }

    public static func resized(_ frame: BoardFrame, width: Double, height: Double, minimum: CanvasSize) -> BoardFrame {
        BoardFrame(x: frame.x, y: frame.y, w: max(minimum.w, snapped(width)), h: max(minimum.h, snapped(height)))
    }

    public static func clamped(_ frame: BoardFrame, in visible: CGSize) -> CGRect {
        let width = Double(frame.w), height = Double(frame.h)
        let x = min(Double(frame.x), max(0, visible.width - width))
        let y = min(Double(frame.y), max(0, visible.height - height))
        return CGRect(x: max(0, x), y: max(0, y), width: width, height: height)
    }

    public static func moved(_ frame: BoardFrame, to origin: CGPoint, among others: [BoardFrame]) -> CanvasMove {
        var rect = CGRect(
            origin: CGPoint(x: max(0, origin.x), y: max(0, origin.y)),
            size: CGSize(width: Double(frame.w), height: Double(frame.h)))
        let rects = others.map(\.rect)
        let vertical = nearest(rect, rects, axis: .vertical)
        if let vertical { rect.origin.x += vertical.delta } else { rect.origin.x = Double(snapped(rect.origin.x)) }
        let horizontal = nearest(rect, rects, axis: .horizontal)
        if let horizontal { rect.origin.y += horizontal.delta } else { rect.origin.y = Double(snapped(rect.origin.y)) }
        rect.origin.x = max(0, rect.origin.x)
        rect.origin.y = max(0, rect.origin.y)
        var guides: [CanvasGuide] = []
        if let vertical {
            guides.append(CanvasGuide(
                axis: .vertical, position: vertical.position,
                start: min(rect.minY, vertical.other.minY), end: max(rect.maxY, vertical.other.maxY), kind: vertical.kind))
        }
        if let horizontal {
            guides.append(CanvasGuide(
                axis: .horizontal, position: horizontal.position,
                start: min(rect.minX, horizontal.other.minX), end: max(rect.maxX, horizontal.other.maxX),
                kind: horizontal.kind))
        }
        let moved = BoardFrame(x: Int(rect.minX.rounded()), y: Int(rect.minY.rounded()), w: frame.w, h: frame.h)
        return CanvasMove(frame: moved, guides: guides)
    }

    public static func snapTargets(
        _ widgets: [BoardWidget], moving id: String, isDrawn: (BoardWidget) -> Bool
    ) -> [BoardWidget] {
        widgets.filter { $0.id != id && isDrawn($0) }
    }

    private struct Hit {
        let delta: Double
        let position: Double
        let other: CGRect
        let kind: CanvasGuide.Kind
    }

    private static func lines(_ rect: CGRect, axis: CanvasGuide.Axis) -> [(Double, CanvasGuide.Kind)] {
        axis == .vertical
            ? [(rect.minX, .edge), (rect.midX, .centre), (rect.maxX, .edge)]
            : [(rect.minY, .edge), (rect.midY, .centre), (rect.maxY, .edge)]
    }

    /// An edge meets only edges and a centre only centres: an edge snapped
    /// to a centre drew a guide where nothing on screen has a line.
    private static func nearest(_ moving: CGRect, _ others: [CGRect], axis: CanvasGuide.Axis) -> Hit? {
        let mine = lines(moving, axis: axis)
        var best: Hit?
        for other in others {
            for (a, kind) in mine {
                for (b, theirs) in lines(other, axis: axis) where theirs == kind {
                    let delta = b - a
                    guard abs(delta) <= guideTolerance, abs(delta) < abs(best?.delta ?? .infinity) else { continue }
                    best = Hit(delta: delta, position: b, other: other, kind: kind)
                }
            }
        }
        return best
    }

    /// Scans rows of the snap from the top-left margin for the first place
    /// that keeps `gap` from every other widget. A widget wider than the band
    /// still gets the margin column.
    public static func firstFreeSpot(
        for size: CanvasSize, avoiding occupied: [BoardFrame], bandWidth: Int = bandWidth
    ) -> BoardFrame {
        var y = margin
        while true {
            var x = margin
            while x == margin || x + size.w <= margin + bandWidth {
                let candidate = BoardFrame(x: x, y: y, w: size.w, h: size.h)
                if !occupied.contains(where: { touches(candidate, $0) }) { return candidate }
                x += snap
            }
            y += snap
        }
    }

    private static func touches(_ a: BoardFrame, _ b: BoardFrame) -> Bool {
        let apart = a.x + a.w + gap <= b.x || b.x + b.w + gap <= a.x || a.y + a.h + gap <= b.y || b.y + b.h + gap <= a.y
        return !apart
    }

    /// The dragged widget draws above all others without changing the board's order.
    public static func stackLevel(of widget: BoardWidget, in board: Board, lifting dragged: String?) -> Double {
        widget.id == dragged ? Double(board.topZ + 1) : Double(widget.z)
    }

    /// Each widget's x on a canvas `to` wide, from its place on one `from`
    /// wide. Widgets that touch move as one group: a group within the margin
    /// of an edge stays at that edge, any other keeps its share of the free
    /// space between the margins, so a centred group stays centred. Swapping
    /// `from` and `to` gives the places back, as long as the groups are the
    /// same: moving a group never changes the gaps inside it.
    public static func aligned(_ rects: [String: CGRect], from: Double, to: Double) -> [String: Double] {
        guard from > 0, to > 0, from != to else { return rects.mapValues { Double($0.minX) } }
        var xs: [String: Double] = [:]
        for group in touchingGroups(rects) {
            let span = group.map { rects[$0]! }.reduce(CGRect.null) { $0.union($1) }
            let shift = groupShift(minX: span.minX, maxX: span.maxX, from: from, to: to)
            for id in group { xs[id] = rects[id]!.minX + shift }
        }
        return xs
    }

    private static func groupShift(minX: Double, maxX: Double, from: Double, to: Double) -> Double {
        let edge = Double(margin)
        let width = maxX - minX
        let freeFrom = from - width - 2 * edge, freeTo = to - width - 2 * edge
        if minX <= edge || freeFrom <= 0 || freeTo <= 0 { return 0 }
        if minX >= edge + freeFrom { return to - from }
        return edge + (minX - edge) * freeTo / freeFrom - minX
    }

    private static func touchingGroups(_ rects: [String: CGRect]) -> [[String]] {
        let ids = rects.keys.sorted()
        var groups: [[String]] = []
        var seen: Set<String> = []
        for start in ids where !seen.contains(start) {
            var group: [String] = []
            var queue = [start]
            seen.insert(start)
            while let id = queue.popLast() {
                group.append(id)
                for other in ids where !seen.contains(other) && touch(rects[id]!, rects[other]!) {
                    seen.insert(other)
                    queue.append(other)
                }
            }
            groups.append(group)
        }
        return groups
    }

    private static func touch(_ a: CGRect, _ b: CGRect) -> Bool {
        let reach = Double(gap)
        return a.minX <= b.maxX + reach && b.minX <= a.maxX + reach
            && a.minY <= b.maxY + reach && b.minY <= a.maxY + reach
    }

    public static func toDisplay(_ rect: CGRect, scale: Double) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    public static func toBoard(_ translation: CGSize, scale: Double) -> CGSize {
        guard scale > 0 else { return translation }
        return CGSize(width: translation.width / scale, height: translation.height / scale)
    }
}
