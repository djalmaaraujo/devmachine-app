import Foundation

public struct SchemaPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum SchemaLayout {
    public struct Metrics: Equatable, Sendable {
        public var cardWidth: Double
        public var headerHeight: Double
        public var rowHeight: Double
        public var columnGap: Double
        public var rowGap: Double
        public var maxRowWidth: Double

        public init(
            cardWidth: Double = 240, headerHeight: Double = 34, rowHeight: Double = 22,
            columnGap: Double = 110, rowGap: Double = 36, maxRowWidth: Double = 3000
        ) {
            self.cardWidth = cardWidth
            self.headerHeight = headerHeight
            self.rowHeight = rowHeight
            self.columnGap = columnGap
            self.rowGap = rowGap
            self.maxRowWidth = maxRowWidth
        }

        public func height(rows: Int) -> Double {
            headerHeight + Double(max(rows, 1)) * rowHeight + rowHeight * 0.4
        }
    }

    public static func layout(_ schema: DBSchema, metrics: Metrics = Metrics()) -> [String: SchemaPoint] {
        let names = schema.tables.map(\.name)
        let heights = Dictionary(schema.tables.map { ($0.name, metrics.height(rows: $0.columns.count)) }, uniquingKeysWith: { _, last in last })
        var parents: [String: Set<String>] = [:]
        var neighbors: [String: Set<String>] = [:]
        for relation in schema.relations where relation.from != relation.to {
            guard heights[relation.from] != nil, heights[relation.to] != nil else { continue }
            parents[relation.from, default: []].insert(relation.to)
            neighbors[relation.from, default: []].insert(relation.to)
            neighbors[relation.to, default: []].insert(relation.from)
        }

        let components = connectedComponents(names, neighbors: neighbors)
        var connected = components.filter { $0.count > 1 }
        let singles = components.filter { $0.count == 1 }.flatMap { $0 }
        connected.sort { $0.count > $1.count }

        var positions: [String: SchemaPoint] = [:]
        var cursorX = 0.0
        var cursorY = 0.0
        var shelfHeight = 0.0

        func place(_ block: [String: SchemaPoint], width: Double, height: Double) {
            if cursorX > 0, cursorX + width > metrics.maxRowWidth {
                cursorX = 0
                cursorY += shelfHeight + metrics.rowGap * 2
                shelfHeight = 0
            }
            for (name, point) in block {
                positions[name] = SchemaPoint(x: point.x + cursorX, y: point.y + cursorY)
            }
            cursorX += width + metrics.columnGap
            shelfHeight = max(shelfHeight, height)
        }

        for component in connected {
            let block = layered(component, parents: parents, neighbors: neighbors, heights: heights, metrics: metrics)
            place(block.positions, width: block.width, height: block.height)
        }

        if !singles.isEmpty {
            let columns = max(1, min(singles.count, Int((metrics.maxRowWidth + metrics.columnGap) / (metrics.cardWidth + metrics.columnGap))))
            var block: [String: SchemaPoint] = [:]
            var columnHeights = Array(repeating: 0.0, count: columns)
            for name in singles {
                let column = columnHeights.indices.min { columnHeights[$0] < columnHeights[$1] } ?? 0
                block[name] = SchemaPoint(x: Double(column) * (metrics.cardWidth + metrics.columnGap), y: columnHeights[column])
                columnHeights[column] += (heights[name] ?? 0) + metrics.rowGap
            }
            let width = Double(min(columns, singles.count)) * (metrics.cardWidth + metrics.columnGap) - metrics.columnGap
            if cursorX > 0 {
                cursorX = 0
                cursorY += shelfHeight + metrics.rowGap * 2
                shelfHeight = 0
            }
            place(block, width: width, height: columnHeights.max() ?? 0)
        }
        return positions
    }

    static func connectedComponents(_ names: [String], neighbors: [String: Set<String>]) -> [[String]] {
        var seen = Set<String>()
        var components: [[String]] = []
        let order = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for name in names where !seen.contains(name) {
            var component: [String] = []
            var stack = [name]
            seen.insert(name)
            while let current = stack.popLast() {
                component.append(current)
                for next in (neighbors[current] ?? []).sorted() where !seen.contains(next) {
                    seen.insert(next)
                    stack.append(next)
                }
            }
            components.append(component.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) })
        }
        return components
    }

    static func layers(_ names: [String], parents: [String: Set<String>]) -> [String: Int] {
        let members = Set(names)
        var layer: [String: Int] = [:]
        var visiting = Set<String>()
        func depth(_ name: String) -> Int {
            if let known = layer[name] { return known }
            if visiting.contains(name) { return 0 }
            visiting.insert(name)
            let parentDepth = (parents[name] ?? []).filter { members.contains($0) }.map { depth($0) + 1 }.max() ?? 0
            visiting.remove(name)
            layer[name] = parentDepth
            return parentDepth
        }
        for name in names { _ = depth(name) }
        return layer
    }

    static func layered(
        _ names: [String], parents: [String: Set<String>], neighbors: [String: Set<String>],
        heights: [String: Double], metrics: Metrics
    ) -> (positions: [String: SchemaPoint], width: Double, height: Double) {
        let layerOf = layers(names, parents: parents)
        let count = (layerOf.values.max() ?? 0) + 1
        var columns = Array(repeating: [String](), count: count)
        for name in names { columns[layerOf[name] ?? 0].append(name) }

        for _ in 0..<4 {
            for index in 1..<max(count, 1) {
                columns[index] = orderedByBarycenter(columns[index], reference: columns[index - 1], neighbors: neighbors)
            }
            if count > 1 {
                for index in stride(from: count - 2, through: 0, by: -1) {
                    columns[index] = orderedByBarycenter(columns[index], reference: columns[index + 1], neighbors: neighbors)
                }
            }
        }

        var positions: [String: SchemaPoint] = [:]
        var tallest = 0.0
        var stacks: [Double] = []
        for column in columns {
            let total = column.reduce(0.0) { $0 + (heights[$1] ?? 0) } + Double(max(column.count - 1, 0)) * metrics.rowGap
            stacks.append(total)
            tallest = max(tallest, total)
        }
        for (index, column) in columns.enumerated() {
            var y = (tallest - stacks[index]) / 2
            let x = Double(index) * (metrics.cardWidth + metrics.columnGap)
            for name in column {
                positions[name] = SchemaPoint(x: x, y: y)
                y += (heights[name] ?? 0) + metrics.rowGap
            }
        }
        let width = Double(count) * (metrics.cardWidth + metrics.columnGap) - metrics.columnGap
        return (positions, width, tallest)
    }

    static func orderedByBarycenter(_ column: [String], reference: [String], neighbors: [String: Set<String>]) -> [String] {
        let index = Dictionary(reference.enumerated().map { ($1, Double($0)) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(column.enumerated().map { ($1, Double($0)) }, uniquingKeysWith: { first, _ in first })
        func center(_ name: String) -> Double {
            let linked = (neighbors[name] ?? []).compactMap { index[$0] }
            guard !linked.isEmpty else { return current[name] ?? 0 }
            return linked.reduce(0, +) / Double(linked.count)
        }
        let keyed: [(name: String, key: Double, order: Int)] = column.enumerated().map { offset, name in
            (name, center(name), offset)
        }
        let sorted = keyed.sorted { lhs, rhs in
            lhs.key == rhs.key ? lhs.order < rhs.order : lhs.key < rhs.key
        }
        return sorted.map(\.name)
    }

    public static func bounds(_ positions: [String: SchemaPoint], schema: DBSchema, metrics: Metrics = Metrics()) -> (width: Double, height: Double) {
        var width = 0.0
        var height = 0.0
        for table in schema.tables {
            guard let point = positions[table.name] else { continue }
            width = max(width, point.x + metrics.cardWidth)
            height = max(height, point.y + metrics.height(rows: table.columns.count))
        }
        return (width, height)
    }
}
