import SwiftUI
import DevmachineCore

struct SchemaPage: View {
    let target: CommandTarget
    var folder: String?
    var onClose: (() -> Void)?
    @Environment(\.dmMetrics) private var m
    @StateObject private var store: SchemaStore
    @State private var zoom: CGFloat = 1
    @State private var search = ""
    @State private var focusRequest: String?
    @State private var pendingReload: PendingReload?

    private enum PendingReload: Equatable {
        case refresh
        case source(String)
    }

    private enum Mode: String, CaseIterable { case view, model }

    init(target: CommandTarget, folder: String? = nil, store: SchemaStore? = nil, onClose: (() -> Void)? = nil) {
        self.target = target
        self.folder = folder
        self.onClose = onClose
        _store = StateObject(wrappedValue: store ?? SchemaStore())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.dmContentBg)
        .onAppear {
            zoom = SchemaZoom.clamp(DMFont.scale)
            store.load(target, folder: folder)
        }
        .onChange(of: target) { _, new in store.load(new, folder: folder) }
        .onChange(of: folder) { _, new in store.load(target, folder: new) }
        .confirmationDialog(
            "Discard your model changes?",
            isPresented: Binding(get: { pendingReload != nil }, set: { if !$0 { pendingReload = nil } })
        ) {
            Button("Discard changes", role: .destructive) {
                guard let reload = pendingReload else { return }
                pendingReload = nil
                perform(reload)
            }
            Button("Cancel", role: .cancel) { pendingReload = nil }
        } message: {
            Text("Reading the schema again replaces the tables you edited. Export first to keep them.")
        }
    }


    private var header: some View {
        HStack(spacing: m.space.md) {
            Text(verbatim: folderName)
                .font(.dm(13, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
                .help(folder ?? target.label)
            if store.sources.count > 1 {
                sourceMenu
            } else if let source = store.selectedSource {
                Text(verbatim: source.title)
                    .font(.dm(11))
                    .foregroundStyle(Color.dmMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if store.status == .loaded {
                Text(verbatim: "\(store.schema.dialect.title) · \(summary)")
                    .font(.dm(11))
                    .foregroundStyle(Color.dmMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: m.space.md)
            if store.status == .loaded {
                if store.isEdited {
                    DMPill(text: "Edited", color: .orange)
                        .help("Changes live only on this page. Export to keep them.")
                    DMButton("Discard", variant: .ghost, size: .small) { store.discardEdits() }
                }
                DMTabStrip(
                    tabs: Mode.allCases,
                    selection: Binding(
                        get: { store.isModeling ? .model : .view },
                        set: { store.isModeling = $0 == .model }),
                    title: { $0 == .view ? "View" : "Model" },
                    fontSize: 11, horizontalPadding: 10, verticalPadding: 3, grouped: true)
                    .fixedSize()
                zoomControls
                DMButton(icon: "arrow.up.left.and.arrow.down.right", label: "Fit to window", size: .small) { store.fit() }
                DMButton(icon: "wand.and.rays", label: "Auto layout", size: .small) { store.autoLayout() }
                exportMenu
            }
            if store.status == .loading {
                ProgressView().controlSize(.small)
            }
            DMIconButton(systemImage: "arrow.clockwise", size: DMMetrics.baseFontSize, tint: nil) { request(.refresh) }
                .help("Look for schema files again")
            if let onClose {
                DMIconButton(systemImage: "xmark", size: DMMetrics.baseFontSize, tint: nil, action: onClose)
                    .help("Close the schema and go back to the terminal")
            }
        }
        .padding(m.pt(10))
    }

    private var folderName: String {
        guard let folder, !folder.isEmpty else { return target.label }
        return (folder as NSString).lastPathComponent
    }

    private var summary: String {
        let schema = store.schema
        return "\(schema.tables.count) \(schema.tables.count == 1 ? "table" : "tables") · "
            + "\(schema.relations.count) \(schema.relations.count == 1 ? "relation" : "relations")"
    }

    private func request(_ reload: PendingReload) {
        if case .source(let id) = reload, id == store.selectedSourceID { return }
        if store.isEdited {
            pendingReload = reload
        } else {
            perform(reload)
        }
    }

    private func perform(_ reload: PendingReload) {
        switch reload {
        case .refresh: store.refresh()
        case .source(let id): store.selectSource(id)
        }
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(store.sources) { source in
                Button {
                    request(.source(source.id))
                } label: {
                    if source.id == store.selectedSourceID {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: source.title)
                    }
                }
            }
        } label: {
            Text(verbatim: store.selectedSource?.title ?? "Source")
                .font(.dm(11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var zoomControls: some View {
        HStack(spacing: m.space.xxs) {
            DMButton(icon: "minus.magnifyingglass", label: "Zoom out", size: .small) {
                zoom = SchemaZoom.clamp(zoom - 0.1)
            }
            Button {
                zoom = 1
            } label: {
                Text(verbatim: String(format: "%.0f%%", zoom * 100))
                    .font(.dm(11, design: .monospaced))
                    .foregroundStyle(Color.dmMuted)
                    .frame(minWidth: m.pt(38))
            }
            .buttonStyle(.plain)
            .help("Actual size")
            DMButton(icon: "plus.magnifyingglass", label: "Zoom in", size: .small) {
                zoom = SchemaZoom.clamp(zoom + 0.1)
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Section("Copy as") {
                ForEach(SchemaExportFormat.allCases, id: \.self) { format in
                    Button(format.title) { store.copy(format) }
                }
            }
            Section("Save as") {
                ForEach(SchemaExportFormat.allCases, id: \.self) { format in
                    Button("\(format.title)…") { store.save(format) }
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.dm(11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }


    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .idle, .loading:
            if store.sources.isEmpty {
                VStack(spacing: m.space.md) {
                    ProgressView().controlSize(.small)
                    Text("Looking for schema files…")
                        .font(.dm(12))
                        .foregroundStyle(Color.dmMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loaded
            }
        case .empty:
            emptyState
        case .failed(let state):
            DMErrorStateView(state: state, retry: { store.refresh() })
                .padding(m.space.xxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            loaded
        }
    }

    private var emptyState: some View {
        VStack(spacing: m.space.md) {
            Image(systemName: "cylinder.split.1x2")
                .font(.dm(28))
                .foregroundStyle(Color.dmMuted)
            Text("No schema found in this folder")
                .font(.dm(13, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
            Text("Looked for Prisma schemas, SQL migrations and dumps, DBML files and Mongoose models.")
                .font(.dm(12))
                .foregroundStyle(Color.dmMuted)
                .multilineTextAlignment(.center)
            DMButton("Start a new model", systemImage: "plus", variant: .outline, size: .small) {
                store.isModeling = true
                store.addTable()
            }
        }
        .padding(m.space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loaded: some View {
        HStack(spacing: 0) {
            tableList
                .frame(width: m.pt(220))
            Divider()
            ZStack(alignment: .bottomLeading) {
                SchemaCanvas(store: store, zoom: $zoom, focusRequest: focusRequest)
                if let error = store.editError {
                    DMBanner(message: error, lineLimit: 2) {
                        DMIconButton(systemImage: "xmark", size: DMMetrics.baseFontSize, tint: nil) { store.editError = nil }
                            .help("Dismiss")
                    }
                    .padding(m.space.md)
                }
            }
            if let selected = store.selectedTable, store.schema.table(selected) != nil {
                Divider()
                SchemaInspector(store: store, tableName: selected, onFocus: focus)
                    .frame(width: m.pt(300))
            }
        }
    }

    private func focus(_ table: String) {
        store.selectedTable = table
        focusRequest = nil
        DispatchQueue.main.async { focusRequest = table }
    }

    private var filteredTables: [DBTable] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.schema.tables }
        return store.schema.tables.filter { table in
            table.name.lowercased().contains(query) || table.columns.contains { $0.name.lowercased().contains(query) }
        }
    }

    private var tableList: some View {
        VStack(alignment: .leading, spacing: 0) {
            DMSearchField(prompt: "Find a table or column", text: $search)
                .padding(.horizontal, m.row.horizontal)
                .padding(.vertical, m.space.md)
            ScrollView {
                VStack(alignment: .leading, spacing: m.space.xxs) {
                    ForEach(filteredTables) { table in
                        tableRow(table)
                    }
                    if store.isModeling {
                        DMButton("New table", systemImage: "plus", variant: .ghost, size: .small) { store.addTable() }
                            .padding(.top, m.space.sm)
                    }
                    if !store.schema.enums.isEmpty {
                        DMSectionLabel(text: "ENUMS")
                            .padding(.top, m.space.lg)
                            .padding(.horizontal, m.space.sm)
                        ForEach(store.schema.enums) { item in
                            VStack(alignment: .leading, spacing: m.space.xxs) {
                                Text(verbatim: item.name)
                                    .font(.dm(12, weight: .medium))
                                    .foregroundStyle(Color.dmRowText)
                                Text(verbatim: item.values.joined(separator: ", "))
                                    .font(.dm(10.5, design: .monospaced))
                                    .foregroundStyle(Color.dmMuted)
                                    .lineLimit(3)
                            }
                            .padding(.horizontal, m.space.sm)
                            .padding(.vertical, m.space.xs)
                        }
                    }
                }
                .padding(.horizontal, m.space.sm)
                .padding(.bottom, m.space.lg)
            }
        }
    }

    private func tableRow(_ table: DBTable) -> some View {
        let selected = store.selectedTable == table.name
        return HStack(spacing: m.space.sm) {
            Image(systemName: SchemaTableKindIcon.name(table.kind))
                .font(.dm(10.5))
                .foregroundStyle(Color.dmMuted)
            Text(verbatim: table.name)
                .font(.dm(12, weight: selected ? .semibold : .regular))
                .foregroundStyle(Color.dmRowText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(verbatim: String(table.columns.count))
                .font(.dm(10.5))
                .foregroundStyle(Color.dmMuted)
        }
        .padding(.horizontal, m.space.sm)
        .padding(.vertical, m.pt(5))
        .background(DMRowBackground(selected: selected))
        .contentShape(Rectangle())
        .onTapGesture { focus(table.name) }
    }
}
