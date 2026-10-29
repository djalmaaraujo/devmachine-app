import Foundation

public struct DBSchema: Equatable, Sendable {
    public enum Dialect: String, Equatable, Sendable, CaseIterable {
        case postgres, mysql, sqlite, sqlserver, mongodb, unknown

        public var title: String {
            switch self {
            case .postgres: return "PostgreSQL"
            case .mysql: return "MySQL"
            case .sqlite: return "SQLite"
            case .sqlserver: return "SQL Server"
            case .mongodb: return "MongoDB"
            case .unknown: return "SQL"
            }
        }

        public var isDocument: Bool { self == .mongodb }

        public init(prismaProvider: String) {
            switch prismaProvider.lowercased() {
            case "postgresql", "postgres", "cockroachdb": self = .postgres
            case "mysql": self = .mysql
            case "sqlite": self = .sqlite
            case "sqlserver": self = .sqlserver
            case "mongodb": self = .mongodb
            default: self = .unknown
            }
        }
    }

    public var dialect: Dialect
    public var tables: [DBTable]
    public var enums: [DBEnum]
    public var relations: [DBRelation]

    public init(dialect: Dialect = .unknown, tables: [DBTable] = [], enums: [DBEnum] = [], relations: [DBRelation] = []) {
        self.dialect = dialect
        self.tables = tables
        self.enums = enums
        self.relations = relations
    }

    public func table(_ name: String) -> DBTable? {
        tables.first { $0.name == name }
    }

    public func tableIndex(_ name: String) -> Int? {
        tables.firstIndex { $0.name == name }
    }

    public func relations(touching table: String) -> [DBRelation] {
        relations.filter { $0.from == table || $0.to == table }
    }

    public func neighborhood(of table: String) -> Set<String> {
        var names: Set<String> = [table]
        for relation in relations(touching: table) {
            names.insert(relation.from)
            names.insert(relation.to)
        }
        return names
    }

    public func foreignKeyColumns(of table: String) -> Set<String> {
        Set(relations.filter { $0.from == table }.flatMap(\.fromColumns))
    }

    public var columnCount: Int { tables.reduce(0) { $0 + $1.columns.count } }
}

public struct DBTable: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case table
        case view
        case collection
        case embedded
    }

    public var id: String { name }
    public var name: String
    public var kind: Kind
    public var columns: [DBColumn]
    public var comment: String?

    public init(name: String, kind: Kind = .table, columns: [DBColumn] = [], comment: String? = nil) {
        self.name = name
        self.kind = kind
        self.columns = columns
        self.comment = comment
    }

    public func column(_ name: String) -> DBColumn? {
        columns.first { $0.name == name }
    }

    public var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
}

public struct DBColumn: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: String
    public var isNullable: Bool
    public var isList: Bool
    public var isPrimaryKey: Bool
    public var isUnique: Bool
    public var defaultValue: String?
    public var comment: String?

    public init(
        name: String, type: String, isNullable: Bool = false, isList: Bool = false,
        isPrimaryKey: Bool = false, isUnique: Bool = false, defaultValue: String? = nil, comment: String? = nil
    ) {
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.isList = isList
        self.isPrimaryKey = isPrimaryKey
        self.isUnique = isUnique
        self.defaultValue = defaultValue
        self.comment = comment
    }

    public var displayType: String {
        type + (isList ? "[]" : "") + (isNullable ? "?" : "")
    }
}

public struct DBEnum: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var values: [String]

    public init(name: String, values: [String]) {
        self.name = name
        self.values = values
    }
}

public struct DBRelation: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case manyToOne
        case oneToOne
        case manyToMany
        case embedded
    }

    public var name: String?
    public var from: String
    public var fromColumns: [String]
    public var to: String
    public var toColumns: [String]
    public var kind: Kind
    public var isOptional: Bool
    public var onDelete: String?

    public init(
        name: String? = nil, from: String, fromColumns: [String], to: String, toColumns: [String],
        kind: Kind = .manyToOne, isOptional: Bool = false, onDelete: String? = nil
    ) {
        self.name = name
        self.from = from
        self.fromColumns = fromColumns
        self.to = to
        self.toColumns = toColumns
        self.kind = kind
        self.isOptional = isOptional
        self.onDelete = onDelete
    }

    public var id: String {
        [name ?? "", from, fromColumns.joined(separator: ","), to, toColumns.joined(separator: ","), kind.rawValue]
            .joined(separator: "|")
    }

    public var label: String {
        let left = fromColumns.isEmpty ? from : "\(from).\(fromColumns.joined(separator: ", "))"
        let right = toColumns.isEmpty ? to : "\(to).\(toColumns.joined(separator: ", "))"
        return "\(left) → \(right)"
    }
}

extension DBSchema {
    public func deduplicated() -> DBSchema {
        var copy = self
        copy.tables = Self.lastOccurrences(tables) { $0.name }
        copy.enums = Self.lastOccurrences(enums) { $0.name }
        copy.relations = Self.lastOccurrences(relations) { $0.id }
        return copy
    }

    static func lastOccurrences<T>(_ items: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        var kept: [T] = []
        for item in items.reversed() where seen.insert(key(item)).inserted { kept.append(item) }
        return kept.reversed()
    }
}
