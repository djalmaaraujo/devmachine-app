import SwiftUI
import DevmachineCore

struct SchemaCanvas: View {
    @ObservedObject var store: SchemaStore
    @Binding var zoom: CGFloat
    var focusRequest: String?
    @GestureState private var drag: (table: String, offset: CGSize)?
    @State private var zoomAtPinchStart: CGFloat?

    private var metrics: SchemaLayout.Metrics { store.metrics }
    private let margin: CGFloat = 60

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    content(viewport: proxy.size)
                }
                .onChange(of: focusRequest) { _, table in
                    guard let table else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { reader.scrollTo(table, anchor: .center) }
                }
                .onChange(of: store.fitRequest) { _, _ in fit(viewport: proxy.size, reader: reader) }
                .onAppear { fit(viewport: proxy.size, reader: reader) }
            }
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = zoomAtPinchStart ?? zoom
                    if zoomAtPinchStart == nil { zoomAtPinchStart = zoom }
                    zoom = SchemaZoom.clamp(start * value.magnification)
                }
                .onEnded { _ in zoomAtPinchStart = nil }
        )
    }

    private func fit(viewport: CGSize, reader: ScrollViewProxy) {
        guard !store.schema.tables.isEmpty, viewport.width > 0, viewport.height > 0 else { return }
        let bounds = SchemaLayout.bounds(store.positions, schema: store.schema, metrics: metrics)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(
            1,
            (viewport.width - margin * 2) / CGFloat(bounds.width),
            (viewport.height - margin * 2) / CGFloat(bounds.height))
        zoom = SchemaZoom.clamp(scale)
        DispatchQueue.main.async { reader.scrollTo(SchemaCanvas.originID, anchor: .topLeading) }
    }

    static let originID = "schema-canvas-origin"

    private func content(viewport: CGSize) -> some View {
        let positions = livePositions
        let bounds = SchemaLayout.bounds(positions, schema: store.schema, metrics: metrics)
        let width = max(viewport.width, CGFloat(bounds.width) * zoom + margin * 2)
        let height = max(viewport.height, CGFloat(bounds.height) * zoom + margin * 2)
        let highlighted = store.selectedTable.map { store.schema.neighborhood(of: $0) }
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { store.selectedTable = nil }
            Color.clear
                .frame(width: 1, height: 1)
                .id(SchemaCanvas.originID)
            Canvas { context, _ in
                drawRelations(in: &context, highlighted: highlighted, positions: positions)
            }
            .allowsHitTesting(false)
            ForEach(store.schema.tables) { table in
                card(table, at: origin(table.name, in: positions), dimmed: highlighted.map { !$0.contains(table.name) } ?? false)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var livePositions: [String: SchemaPoint] {
        guard let drag else { return store.positions }
        var positions = store.positions
        if let point = positions[drag.table] {
            positions[drag.table] = SchemaPoint(
                x: max(0, point.x + Double(drag.offset.width / zoom)),
                y: max(0, point.y + Double(drag.offset.height / zoom)))
        }
        return positions
    }

    private func origin(_ table: String, in positions: [String: SchemaPoint]) -> CGPoint {
        let point = positions[table] ?? SchemaPoint(x: 0, y: 0)
        return CGPoint(x: margin + CGFloat(point.x) * zoom, y: margin + CGFloat(point.y) * zoom)
    }

    private func card(_ table: DBTable, at point: CGPoint, dimmed: Bool) -> some View {
        let foreignKeys = store.schema.foreignKeyColumns(of: table.name)
        return SchemaTableCard(
            table: table, foreignKeys: foreignKeys, metrics: metrics, zoom: zoom,
            isSelected: store.selectedTable == table.name)
            .id(table.name)
            .opacity(dimmed ? 0.35 : 1)
            .zIndex(drag?.table == table.name ? 1 : 0)
            .onTapGesture { store.selectedTable = table.name }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .updating($drag) { value, state, _ in
                        state = (table.name, value.translation)
                    }
                    .onEnded { value in
                        guard let start = store.positions[table.name] else { return }
                        store.move(table.name, to: SchemaPoint(
                            x: start.x + Double(value.translation.width / zoom),
                            y: start.y + Double(value.translation.height / zoom)))
                    }
            )
            .padding(.leading, point.x)
            .padding(.top, point.y)
    }


    private func rowY(_ table: DBTable, top: CGFloat, column: String?) -> CGFloat {
        let header = CGFloat(metrics.headerHeight) * zoom
        guard let column, let index = table.columns.firstIndex(where: { $0.name == column }) else {
            return top + header / 2
        }
        return top + header + (CGFloat(index) + 0.5) * CGFloat(metrics.rowHeight) * zoom
    }

    private func drawRelations(in context: inout GraphicsContext, highlighted: Set<String>?, positions: [String: SchemaPoint]) {
        let width = CGFloat(metrics.cardWidth) * zoom
        for relation in store.schema.relations {
            guard let from = store.schema.table(relation.from), let to = store.schema.table(relation.to) else { continue }
            let active = store.selectedTable.map { relation.from == $0 || relation.to == $0 } ?? false
            let faded = highlighted != nil && !active
            let fromOrigin = origin(from.name, in: positions)
            let toOrigin = origin(to.name, in: positions)
            let startY = rowY(from, top: fromOrigin.y, column: relation.fromColumns.first)
            let endY = rowY(to, top: toOrigin.y, column: relation.toColumns.first)
            let start: CGPoint
            let end: CGPoint
            let startDirection: CGFloat
            let endDirection: CGFloat
            if from.name == to.name {
                start = CGPoint(x: fromOrigin.x + width, y: startY)
                end = CGPoint(x: fromOrigin.x + width, y: endY == startY ? startY + CGFloat(metrics.rowHeight) * zoom : endY)
                startDirection = 1
                endDirection = 1
            } else if fromOrigin.x + width / 2 <= toOrigin.x + width / 2 {
                let sameColumn = abs(fromOrigin.x - toOrigin.x) < width
                start = CGPoint(x: fromOrigin.x + width, y: startY)
                end = CGPoint(x: sameColumn ? toOrigin.x + width : toOrigin.x, y: endY)
                startDirection = 1
                endDirection = sameColumn ? 1 : -1
            } else {
                start = CGPoint(x: fromOrigin.x, y: startY)
                end = CGPoint(x: toOrigin.x + width, y: endY)
                startDirection = -1
                endDirection = 1
            }
            let reach = max(40 * zoom, abs(end.x - start.x) / 2)
            var path = Path()
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + startDirection * reach, y: start.y),
                control2: CGPoint(x: end.x + endDirection * reach, y: end.y))
            let color = active ? Color.accentColor : Color.dmMuted.opacity(faded ? 0.25 : 0.8)
            let style = StrokeStyle(
                lineWidth: (active ? 1.8 : 1.2) * max(zoom, 0.6),
                dash: relation.kind == .embedded || store.schema.dialect.isDocument ? [5 * zoom, 4 * zoom] : [])
            context.stroke(path, with: .color(color), style: style)
            drawEnd(in: &context, at: start, direction: startDirection, many: relation.kind != .oneToOne && relation.kind != .embedded, optional: false, color: color)
            drawEnd(in: &context, at: end, direction: endDirection, many: relation.kind == .manyToMany, optional: relation.isOptional, color: color)
        }
    }

    private func drawEnd(in context: inout GraphicsContext, at point: CGPoint, direction: CGFloat, many: Bool, optional: Bool, color: Color) {
        let unit = 6 * zoom
        var path = Path()
        if many {
            let tip = CGPoint(x: point.x + direction * unit * 2, y: point.y)
            path.move(to: CGPoint(x: point.x, y: point.y - unit))
            path.addLine(to: tip)
            path.move(to: CGPoint(x: point.x, y: point.y + unit))
            path.addLine(to: tip)
            path.move(to: point)
            path.addLine(to: tip)
        } else {
            let x = point.x + direction * unit * 1.4
            path.move(to: CGPoint(x: x, y: point.y - unit))
            path.addLine(to: CGPoint(x: x, y: point.y + unit))
            if !optional {
                let second = point.x + direction * unit * 2.2
                path.move(to: CGPoint(x: second, y: point.y - unit))
                path.addLine(to: CGPoint(x: second, y: point.y + unit))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.2 * max(zoom, 0.6))
        if optional {
            let center = CGPoint(x: point.x + direction * unit * 3, y: point.y)
            let circle = Path(ellipseIn: CGRect(x: center.x - unit * 0.6, y: center.y - unit * 0.6, width: unit * 1.2, height: unit * 1.2))
            context.fill(circle, with: .color(Color.dmContentBg))
            context.stroke(circle, with: .color(color), lineWidth: 1.2 * max(zoom, 0.6))
        }
    }
}

enum SchemaZoom {
    static let range: ClosedRange<CGFloat> = 0.3...2
    static func clamp(_ value: CGFloat) -> CGFloat { min(max(value, range.lowerBound), range.upperBound) }
}

struct SchemaTableCard: View {
    let table: DBTable
    let foreignKeys: Set<String>
    let metrics: SchemaLayout.Metrics
    let zoom: CGFloat
    let isSelected: Bool

    private var width: CGFloat { CGFloat(metrics.cardWidth) * zoom }
    private var rowHeight: CGFloat { CGFloat(metrics.rowHeight) * zoom }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 0) {
                if table.columns.isEmpty {
                    Text(verbatim: "No columns")
                        .font(.system(size: 10.5 * zoom))
                        .foregroundStyle(Color.dmMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: rowHeight)
                        .padding(.horizontal, 10 * zoom)
                }
                ForEach(table.columns) { column in
                    row(column)
                }
            }
            .padding(.bottom, rowHeight * 0.4)
        }
        .frame(width: width, height: CGFloat(metrics.height(rows: table.columns.count)) * zoom, alignment: .top)
        .background(Color.dmSidebarBg, in: RoundedRectangle(cornerRadius: 8 * zoom, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8 * zoom, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.dmStroke, lineWidth: isSelected ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 6 * zoom, y: 2 * zoom)
        .contentShape(RoundedRectangle(cornerRadius: 8 * zoom))
    }

    private var header: some View {
        HStack(spacing: 6 * zoom) {
            Image(systemName: SchemaTableKindIcon.name(table.kind))
                .font(.system(size: 10.5 * zoom))
                .foregroundStyle(Color.dmMuted)
            Text(verbatim: table.name)
                .font(.system(size: 12 * zoom, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10 * zoom)
        .frame(height: CGFloat(metrics.headerHeight) * zoom)
        .background(Color.dmBand)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8 * zoom, topTrailingRadius: 8 * zoom, style: .continuous))
        .help(table.comment ?? table.name)
    }

    private func row(_ column: DBColumn) -> some View {
        HStack(spacing: 5 * zoom) {
            Group {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill").foregroundStyle(Color.yellow.opacity(0.85))
                } else if foreignKeys.contains(column.name) {
                    Image(systemName: "link").foregroundStyle(Color.accentColor)
                } else if column.isUnique {
                    Image(systemName: "staroflife.fill").foregroundStyle(Color.dmMuted)
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 8.5 * zoom))
            .frame(width: 11 * zoom)
            Text(verbatim: column.name)
                .font(.system(size: 11 * zoom, weight: column.isPrimaryKey ? .medium : .regular))
                .foregroundStyle(Color.dmRowText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4 * zoom)
            Text(verbatim: column.displayType)
                .font(.system(size: 10 * zoom, design: .monospaced))
                .foregroundStyle(Color.dmMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10 * zoom)
        .frame(height: rowHeight)
        .help(column.comment ?? "\(column.name): \(column.displayType)")
    }
}

enum SchemaTableKindIcon {
    static func name(_ kind: DBTable.Kind) -> String {
        switch kind {
        case .table: return "tablecells"
        case .view: return "eye"
        case .collection: return "doc.on.doc"
        case .embedded: return "shippingbox"
        }
    }
}
