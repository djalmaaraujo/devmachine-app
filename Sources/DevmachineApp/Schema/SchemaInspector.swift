import SwiftUI
import DevmachineCore

struct SchemaInspector: View {
    @ObservedObject var store: SchemaStore
    let tableName: String
    let onFocus: (String) -> Void
    @Environment(\.dmMetrics) private var m
    @State private var nameDraft = ""

    private var table: DBTable? { store.schema.table(tableName) }

    var body: some View {
        if let table {
            ScrollView {
                VStack(alignment: .leading, spacing: m.space.lg) {
                    title(table)
                    columns(table)
                    relations
                    if store.isModeling {
                        DMButton("Delete table", systemImage: "trash", variant: .dangerOutline, size: .small) {
                            store.removeTable(table.name)
                        }
                    }
                }
                .padding(m.space.lg)
            }
            .id(tableName)
        }
    }

    private func title(_ table: DBTable) -> some View {
        VStack(alignment: .leading, spacing: m.space.xs) {
            HStack(spacing: m.space.sm) {
                Image(systemName: SchemaTableKindIcon.name(table.kind))
                    .foregroundStyle(Color.dmMuted)
                if store.isModeling {
                    TextField("Table name", text: $nameDraft)
                        .dmField()
                        .onAppear { nameDraft = table.name }
                        .onSubmit { store.renameTable(table.name, to: nameDraft) }
                } else {
                    Text(verbatim: table.name)
                        .font(.dm(14, weight: .semibold))
                        .foregroundStyle(Color.dmRowText)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                DMIconButton(systemImage: "xmark", size: DMMetrics.baseFontSize, tint: nil) { store.selectedTable = nil }
                    .help("Close")
            }
            if let comment = table.comment {
                Text(verbatim: comment)
                    .font(.dm(11.5))
                    .foregroundStyle(Color.dmMuted)
            }
        }
    }

    private func columns(_ table: DBTable) -> some View {
        VStack(alignment: .leading, spacing: m.space.xs) {
            DMSectionLabel(text: table.kind == .collection || table.kind == .embedded ? "FIELDS" : "COLUMNS")
            ForEach(table.columns) { column in
                if store.isModeling {
                    SchemaColumnEditor(store: store, tableName: table.name, column: column)
                } else {
                    columnRow(column, foreignKey: store.schema.foreignKeyColumns(of: table.name).contains(column.name))
                }
            }
            if store.isModeling {
                HStack(spacing: m.space.sm) {
                    DMButton("Add column", systemImage: "plus", variant: .ghost, size: .small) {
                        store.edit { try $0.addColumn(to: table.name) }
                    }
                    Menu {
                        ForEach(store.schema.tables.filter { $0.kind != .embedded }) { other in
                            Button(other.name) { store.edit { try $0.addReference(from: table.name, to: other.name) } }
                        }
                    } label: {
                        Label("Add reference", systemImage: "link")
                            .font(.dm(11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    private func columnRow(_ column: DBColumn, foreignKey: Bool) -> some View {
        VStack(alignment: .leading, spacing: m.space.xxs) {
            HStack(spacing: m.space.sm) {
                Text(verbatim: column.name)
                    .font(.dm(12, weight: column.isPrimaryKey ? .semibold : .regular))
                    .foregroundStyle(Color.dmRowText)
                Spacer(minLength: m.space.sm)
                Text(verbatim: column.displayType)
                    .font(.dm(11, design: .monospaced))
                    .foregroundStyle(Color.dmMuted)
            }
            let badges = Self.badges(column, foreignKey: foreignKey)
            if !badges.isEmpty || column.defaultValue != nil {
                HStack(spacing: m.space.xs) {
                    ForEach(badges, id: \.self) { DMPill(text: $0, color: .dmMuted) }
                    if let value = column.defaultValue {
                        Text(verbatim: "= \(value)")
                            .font(.dm(10.5, design: .monospaced))
                            .foregroundStyle(Color.dmMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            if let comment = column.comment {
                Text(verbatim: comment)
                    .font(.dm(11))
                    .foregroundStyle(Color.dmMuted)
            }
        }
        .padding(.vertical, m.space.xs)
        .padding(.horizontal, m.space.sm)
        .background(Color.dmHover, in: RoundedRectangle(cornerRadius: m.radius.row))
        .textSelection(.enabled)
    }

    static func badges(_ column: DBColumn, foreignKey: Bool) -> [String] {
        var badges: [String] = []
        if column.isPrimaryKey { badges.append("PK") }
        if foreignKey { badges.append("FK") }
        if column.isUnique { badges.append("UNIQUE") }
        if column.isNullable { badges.append("NULL") }
        if column.isList { badges.append("LIST") }
        return badges
    }

    private var relations: some View {
        let list = store.schema.relations(touching: tableName)
        return VStack(alignment: .leading, spacing: m.space.xs) {
            if !list.isEmpty {
                DMSectionLabel(text: "RELATIONS")
            }
            ForEach(list) { relation in
                HStack(spacing: m.space.sm) {
                    VStack(alignment: .leading, spacing: m.space.xxs) {
                        Text(verbatim: relation.label)
                            .font(.dm(11.5, design: .monospaced))
                            .foregroundStyle(Color.dmRowText)
                            .lineLimit(2)
                        Text(verbatim: Self.kindText(relation))
                            .font(.dm(10.5))
                            .foregroundStyle(Color.dmMuted)
                    }
                    Spacer(minLength: 0)
                    if store.isModeling {
                        DMIconButton(systemImage: "trash", size: 11, tint: nil) {
                            store.edit { $0.removeRelation(relation.id) }
                        }
                        .help("Remove relation")
                    }
                }
                .padding(.vertical, m.space.xs)
                .padding(.horizontal, m.space.sm)
                .background(Color.dmHover, in: RoundedRectangle(cornerRadius: m.radius.row))
                .contentShape(Rectangle())
                .onTapGesture {
                    onFocus(relation.from == tableName ? relation.to : relation.from)
                }
            }
        }
    }

    static func kindText(_ relation: DBRelation) -> String {
        var text: String
        switch relation.kind {
        case .manyToOne: text = "many to one"
        case .oneToOne: text = "one to one"
        case .manyToMany: text = "many to many"
        case .embedded: text = "embedded"
        }
        if relation.isOptional { text += " · optional" }
        if let onDelete = relation.onDelete { text += " · on delete \(onDelete.lowercased())" }
        return text
    }
}

struct SchemaColumnEditor: View {
    @ObservedObject var store: SchemaStore
    let tableName: String
    let column: DBColumn
    @Environment(\.dmMetrics) private var m
    @State private var name = ""
    @State private var type = ""

    var body: some View {
        VStack(alignment: .leading, spacing: m.space.xs) {
            HStack(spacing: m.space.xs) {
                TextField("name", text: $name)
                    .dmField()
                    .onSubmit { commit { $0.name = name } }
                TextField("type", text: $type)
                    .dmField()
                    .font(.dm(12, design: .monospaced))
                    .frame(width: m.pt(100))
                    .onSubmit { commit { $0.type = type } }
            }
            HStack(spacing: m.space.md) {
                toggle("PK", \.isPrimaryKey)
                toggle("Null", \.isNullable)
                toggle("Unique", \.isUnique)
                toggle("List", \.isList)
                Spacer(minLength: 0)
                DMIconButton(systemImage: "arrow.up", size: 10, tint: nil) {
                    store.edit { $0.moveColumn(column.name, in: tableName, by: -1) }
                }
                .help("Move up")
                DMIconButton(systemImage: "arrow.down", size: 10, tint: nil) {
                    store.edit { $0.moveColumn(column.name, in: tableName, by: 1) }
                }
                .help("Move down")
                DMIconButton(systemImage: "trash", size: 11, tint: nil) {
                    store.edit { $0.removeColumn(column.name, from: tableName) }
                }
                .help("Remove column")
            }
        }
        .padding(m.space.sm)
        .background(Color.dmHover, in: RoundedRectangle(cornerRadius: m.radius.row))
        .onAppear {
            name = column.name
            type = column.type
        }
        .onChange(of: column) { _, new in
            name = new.name
            type = new.type
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<DBColumn, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { column[keyPath: key] },
            set: { value in commit { $0[keyPath: key] = value } }))
            .toggleStyle(.checkbox)
            .font(.dm(11))
    }

    private func commit(_ change: (inout DBColumn) -> Void) {
        var updated = column
        change(&updated)
        guard updated != column else { return }
        let old = column.name
        store.edit { try $0.updateColumn(in: tableName, column: old, to: updated) }
    }
}
