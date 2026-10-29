import Foundation

public enum SchemaEditError: Error, Equatable, Sendable {
    case emptyName
    case duplicateTable(String)
    case duplicateColumn(String)
    case missingTable(String)
    case missingColumn(String)

    public var message: String {
        switch self {
        case .emptyName: return "A name can't be empty."
        case .duplicateTable(let name): return "There is already a table named \(name)."
        case .duplicateColumn(let name): return "There is already a column named \(name)."
        case .missingTable(let name): return "No table named \(name)."
        case .missingColumn(let name): return "No column named \(name)."
        }
    }
}

extension DBSchema {
    public func freeTableName(_ base: String = "new_table") -> String {
        var name = base
        var counter = 2
        while table(name) != nil {
            name = "\(base)_\(counter)"
            counter += 1
        }
        return name
    }

    @discardableResult
    public mutating func addTable(_ rawName: String? = nil) throws -> String {
        let name = (rawName ?? freeTableName()).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw SchemaEditError.emptyName }
        guard table(name) == nil else { throw SchemaEditError.duplicateTable(name) }
        let idType = dialect == .mongodb ? "ObjectId" : "Int"
        let idDefault = dialect == .mongodb ? "auto()" : "autoincrement()"
        let kind: DBTable.Kind = dialect == .mongodb ? .collection : .table
        tables.append(DBTable(name: name, kind: kind, columns: [
            DBColumn(name: dialect == .mongodb ? "_id" : "id", type: idType, isPrimaryKey: true, defaultValue: idDefault),
        ]))
        return name
    }

    public mutating func renameTable(_ old: String, to rawNew: String) throws {
        let new = rawNew.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty else { throw SchemaEditError.emptyName }
        guard let index = tableIndex(old) else { throw SchemaEditError.missingTable(old) }
        guard new == old || table(new) == nil else { throw SchemaEditError.duplicateTable(new) }
        tables[index].name = new
        for r in relations.indices {
            if relations[r].from == old { relations[r].from = new }
            if relations[r].to == old { relations[r].to = new }
        }
    }

    public mutating func removeTable(_ name: String) {
        tables.removeAll { $0.name == name }
        relations.removeAll { $0.from == name || $0.to == name }
    }

    @discardableResult
    public mutating func addColumn(to tableName: String, name rawName: String? = nil, type: String? = nil) throws -> String {
        guard let index = tableIndex(tableName) else { throw SchemaEditError.missingTable(tableName) }
        var name = (rawName ?? "column").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw SchemaEditError.emptyName }
        if rawName == nil {
            var counter = 2
            let base = name
            while tables[index].column(name) != nil {
                name = "\(base)_\(counter)"
                counter += 1
            }
        } else if tables[index].column(name) != nil {
            throw SchemaEditError.duplicateColumn(name)
        }
        tables[index].columns.append(DBColumn(name: name, type: type ?? defaultColumnType))
        return name
    }

    public var defaultColumnType: String {
        switch dialect {
        case .mongodb: return "String"
        case .postgres: return "text"
        case .mysql: return "varchar(191)"
        default: return "String"
        }
    }

    public mutating func updateColumn(in tableName: String, column old: String, to column: DBColumn) throws {
        guard let t = tableIndex(tableName) else { throw SchemaEditError.missingTable(tableName) }
        guard let c = tables[t].columns.firstIndex(where: { $0.name == old }) else { throw SchemaEditError.missingColumn(old) }
        let name = column.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw SchemaEditError.emptyName }
        guard name == old || tables[t].column(name) == nil else { throw SchemaEditError.duplicateColumn(name) }
        var updated = column
        updated.name = name
        tables[t].columns[c] = updated
        guard name != old else { return }
        for r in relations.indices {
            if relations[r].from == tableName {
                relations[r].fromColumns = relations[r].fromColumns.map { $0 == old ? name : $0 }
            }
            if relations[r].to == tableName {
                relations[r].toColumns = relations[r].toColumns.map { $0 == old ? name : $0 }
            }
        }
    }

    public mutating func removeColumn(_ column: String, from tableName: String) {
        guard let t = tableIndex(tableName) else { return }
        tables[t].columns.removeAll { $0.name == column }
        relations.removeAll { relation in
            (relation.from == tableName && relation.fromColumns.contains(column))
                || (relation.to == tableName && relation.toColumns.contains(column))
        }
    }

    public mutating func moveColumn(_ column: String, in tableName: String, by offset: Int) {
        guard let t = tableIndex(tableName), let c = tables[t].columns.firstIndex(where: { $0.name == column }) else { return }
        let target = c + offset
        guard tables[t].columns.indices.contains(target) else { return }
        tables[t].columns.swapAt(c, target)
    }

    @discardableResult
    public mutating func addReference(from tableName: String, to target: String, column: String? = nil) throws -> DBRelation {
        guard let t = tableIndex(tableName) else { throw SchemaEditError.missingTable(tableName) }
        guard let targetTable = table(target) else { throw SchemaEditError.missingTable(target) }
        let key = targetTable.primaryKey.first.flatMap { targetTable.column($0) }
            ?? DBColumn(name: "id", type: "Int")
        let suffix = dialect == .mongodb || key.name.hasPrefix("_") ? "Id" : "_id"
        let base = column ?? (SchemaExport.lowerFirst(SchemaExport.identifier(target)) + suffix)
        var name = base
        var counter = 2
        while tables[t].column(name) != nil, column == nil {
            name = "\(base)\(counter)"
            counter += 1
        }
        if tables[t].column(name) == nil {
            tables[t].columns.append(DBColumn(name: name, type: key.type, isNullable: false))
        }
        let relation = DBRelation(
            from: tableName, fromColumns: [name], to: target, toColumns: [key.name], kind: .manyToOne)
        relations.append(relation)
        return relation
    }

    public mutating func removeRelation(_ id: String) {
        relations.removeAll { $0.id == id }
    }
}
