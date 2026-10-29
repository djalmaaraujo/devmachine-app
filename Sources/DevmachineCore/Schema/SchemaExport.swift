import Foundation

public enum SchemaExportFormat: String, CaseIterable, Sendable {
    case prisma, postgres, mysql, dbml

    public var title: String {
        switch self {
        case .prisma: return "Prisma"
        case .postgres: return "PostgreSQL DDL"
        case .mysql: return "MySQL DDL"
        case .dbml: return "DBML"
        }
    }

    public var fileExtension: String {
        switch self {
        case .prisma: return "prisma"
        case .postgres, .mysql: return "sql"
        case .dbml: return "dbml"
        }
    }
}

public enum DBTypeMapping {
    static let prismaScalars: Set<String> = ["String", "Int", "BigInt", "Float", "Decimal", "Boolean", "DateTime", "Json", "Bytes"]

    public static func prisma(_ type: String, enums: Set<String> = []) -> String {
        if prismaScalars.contains(type) || enums.contains(type) { return type }
        let lower = type.lowercased()
        let base = lower.split(separator: "(").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? lower
        switch base {
        case "text", "varchar", "character varying", "char", "character", "uuid", "citext", "nvarchar", "nchar",
             "string", "objectid", "tinytext", "mediumtext", "longtext", "inet", "cidr", "mixed":
            return "String"
        case "int", "integer", "int4", "smallint", "int2", "serial", "smallserial", "mediumint", "tinyint", "number":
            return lower.hasPrefix("tinyint(1)") ? "Boolean" : "Int"
        case "bigint", "int8", "bigserial":
            return "BigInt"
        case "boolean", "bool", "bit":
            return "Boolean"
        case "real", "float", "float4", "float8", "double", "double precision":
            return "Float"
        case "numeric", "decimal", "money", "decimal128":
            return "Decimal"
        case "timestamp", "timestamptz", "timestamp with time zone", "timestamp without time zone", "date", "time",
             "timetz", "datetime", "datetime2", "smalldatetime":
            return "DateTime"
        case "json", "jsonb", "object", "map":
            return "Json"
        case "bytea", "blob", "binary", "varbinary", "longblob", "buffer":
            return "Bytes"
        default:
            if lower.hasPrefix("timestamp") { return "DateTime" }
            return "Unsupported(\"\(type)\")"
        }
    }

    public static func sql(_ type: String, dialect: SchemaExportFormat, enums: Set<String> = []) -> String {
        let mysql = dialect == .mysql
        if enums.contains(type) { return mysql ? "VARCHAR(64)" : quote(type, dialect) }
        switch prisma(type, enums: enums) {
        case "String":
            if !prismaScalars.contains(type), !["objectid", "mixed", "string"].contains(type.lowercased()) { return type }
            return mysql ? "VARCHAR(191)" : "TEXT"
        case "Int": return prismaScalars.contains(type) ? "INTEGER" : type
        case "BigInt": return "BIGINT"
        case "Float": return "DOUBLE PRECISION"
        case "Decimal": return "DECIMAL(65,30)"
        case "Boolean": return "BOOLEAN"
        case "DateTime": return prismaScalars.contains(type) ? (mysql ? "DATETIME(3)" : "TIMESTAMP(3)") : type
        case "Json": return mysql ? "JSON" : "JSONB"
        case "Bytes": return mysql ? "LONGBLOB" : "BYTEA"
        default: return type
        }
    }

    static func quote(_ name: String, _ dialect: SchemaExportFormat) -> String {
        let parts = name.split(separator: ".").map(String.init)
        return parts.map { dialect == .mysql ? "`\($0)`" : "\"\($0)\"" }.joined(separator: ".")
    }
}

public enum SchemaExport {
    public static func render(_ schema: DBSchema, as format: SchemaExportFormat) -> String {
        switch format {
        case .prisma: return prisma(schema)
        case .postgres, .mysql: return sql(schema, dialect: format)
        case .dbml: return dbml(schema)
        }
    }

    static func identifier(_ name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        let text = String(cleaned)
        return text.first?.isNumber == true ? "_" + text : text
    }

    static func modelName(_ name: String) -> String {
        let base = identifier(name)
        return base.prefix(1).uppercased() + base.dropFirst()
    }


    static func prisma(_ schema: DBSchema) -> String {
        let provider: String
        switch schema.dialect {
        case .mysql: provider = "mysql"
        case .sqlite: provider = "sqlite"
        case .sqlserver: provider = "sqlserver"
        case .mongodb: provider = "mongodb"
        default: provider = "postgresql"
        }
        var out = """
        datasource db {
          provider = "\(provider)"
          url      = env("DATABASE_URL")
        }

        generator client {
          provider = "prisma-client-js"
        }

        """
        let enumNames = Set(schema.enums.map(\.name))
        let names = Dictionary(schema.tables.map { ($0.name, modelName($0.name)) }, uniquingKeysWith: { _, last in last })
        let composites = Dictionary(
            schema.tables.filter { $0.kind == .embedded }.map { ($0.name, modelName($0.name)) },
            uniquingKeysWith: { _, last in last })

        var relationFields: [String: [String]] = [:]
        var usedNames: [String: Set<String>] = [:]
        for table in schema.tables {
            usedNames[table.name] = Set(table.columns.map(\.name))
        }
        func freeName(_ base: String, in table: String) -> String {
            var name = base
            var counter = 2
            while usedNames[table, default: []].contains(name) {
                name = base + String(counter)
                counter += 1
            }
            usedNames[table, default: []].insert(name)
            return name
        }
        let pairCounts = Dictionary(grouping: schema.relations, by: { [$0.from, $0.to].sorted().joined(separator: "|") }).mapValues(\.count)
        for (index, relation) in schema.relations.enumerated() where relation.kind != .embedded {
            guard let fromModel = names[relation.from], let toModel = names[relation.to] else { continue }
            let pairKey = [relation.from, relation.to].sorted().joined(separator: "|")
            let needsName = (pairCounts[pairKey] ?? 0) > 1 || relation.from == relation.to
            let relationName = needsName ? "\"\(relation.name.map(identifier) ?? "\(fromModel)\(toModel)\(index)")\"" : nil
            switch relation.kind {
            case .manyToMany:
                let forward = freeName(lowerFirst(toModel) + "s", in: relation.from)
                let backward = freeName(lowerFirst(fromModel) + "s", in: relation.to)
                let attr = relationName.map { " @relation(\($0))" } ?? ""
                relationFields[relation.from, default: []].append("\(forward) \(toModel)[]\(attr)")
                relationFields[relation.to, default: []].append("\(backward) \(fromModel)[]\(attr)")
            default:
                let baseName = relation.fromColumns.first.map(stripIdSuffix) ?? lowerFirst(toModel)
                let forward = freeName(baseName.isEmpty || baseName == relation.fromColumns.first ? lowerFirst(toModel) : baseName, in: relation.from)
                var args: [String] = []
                if let relationName { args.append(relationName) }
                args.append("fields: [\(relation.fromColumns.joined(separator: ", "))]")
                if !relation.toColumns.isEmpty { args.append("references: [\(relation.toColumns.joined(separator: ", "))]") }
                if let onDelete = relation.onDelete, let action = prismaAction(onDelete) { args.append("onDelete: \(action)") }
                relationFields[relation.from, default: []].append(
                    "\(forward) \(toModel)\(relation.isOptional ? "?" : "") @relation(\(args.joined(separator: ", ")))")
                let backward = freeName(lowerFirst(fromModel) + (relation.kind == .oneToOne ? "" : "s"), in: relation.to)
                let attr = relationName.map { " @relation(\($0))" } ?? ""
                relationFields[relation.to, default: []].append(
                    "\(backward) \(fromModel)\(relation.kind == .oneToOne ? "?" : "[]")\(attr)")
            }
        }

        for table in schema.tables {
            let model = names[table.name] ?? table.name
            let keyword = table.kind == .embedded ? "type" : (table.kind == .view ? "view" : "model")
            out += "\n"
            if let comment = table.comment { out += "/// \(comment)\n" }
            out += "\(keyword) \(model) {\n"
            var lines: [(String, String)] = []
            let compositeKey = table.primaryKey.count > 1
            for column in table.columns {
                let type = (composites[column.type] ?? DBTypeMapping.prisma(column.type, enums: enumNames))
                    + (column.isList ? "[]" : (column.isNullable ? "?" : ""))
                var attributes: [String] = []
                if column.isPrimaryKey, !compositeKey { attributes.append("@id") }
                if column.isUnique, !column.isPrimaryKey { attributes.append("@unique") }
                if let value = column.defaultValue, let rendered = prismaDefault(value, type: type, isEnum: enumNames.contains(column.type)) {
                    attributes.append("@default(\(rendered))")
                }
                let name = identifier(column.name)
                if name != column.name { attributes.append("@map(\"\(column.name)\")") }
                lines.append((name, ([type] + attributes).joined(separator: " ")))
            }
            for field in relationFields[table.name] ?? [] {
                let parts = field.split(separator: " ", maxSplits: 1).map(String.init)
                lines.append((parts[0], parts.count > 1 ? parts[1] : ""))
            }
            let width = (lines.map(\.0.count).max() ?? 0) + 1
            for (name, rest) in lines {
                out += "  " + name.padding(toLength: width, withPad: " ", startingAt: 0) + rest + "\n"
            }
            if compositeKey { out += "\n  @@id([\(table.primaryKey.joined(separator: ", "))])\n" }
            if identifier(table.name) != model || table.name.contains(".") {
                out += "  @@map(\"\(table.name.split(separator: ".").last.map(String.init) ?? table.name)\")\n"
            }
            out += "}\n"
        }
        for item in schema.enums {
            out += "\nenum \(identifier(item.name)) {\n"
            for value in item.values { out += "  \(identifier(value))\n" }
            out += "}\n"
        }
        return out
    }

    static func lowerFirst(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }

    static func stripIdSuffix(_ column: String) -> String {
        for suffix in ["_id", "Id", "_ID", "ID"] where column.hasSuffix(suffix) && column.count > suffix.count {
            return String(column.dropLast(suffix.count))
        }
        return column
    }

    static func prismaAction(_ value: String) -> String? {
        switch value.uppercased() {
        case "CASCADE": return "Cascade"
        case "SET NULL": return "SetNull"
        case "SET DEFAULT": return "SetDefault"
        case "RESTRICT": return "Restrict"
        case "NO ACTION": return "NoAction"
        default: return value.first?.isUppercase == true && !value.contains(" ") ? value : nil
        }
    }

    static func prismaDefault(_ raw: String, type: String, isEnum: Bool = false) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let lower = value.lowercased()
        if lower.hasPrefix("dbgenerated(") { return value }
        if isEnum, let member = enumMember(value) { return identifier(member) }
        if lower.hasSuffix("()") && !lower.contains("nextval") && !lower.contains(" ") {
            switch lower {
            case "now()", "current_timestamp()": return "now()"
            case "gen_random_uuid()", "uuid_generate_v4()", "uuid()": return "uuid()"
            default: return value
            }
        }
        if lower.contains("nextval") { return "autoincrement()" }
        if lower == "current_timestamp" || lower == "date.now" { return "now()" }
        if lower == "true" || lower == "false" { return lower }
        if Double(value) != nil { return value }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            let inner = String(value.dropFirst().dropLast())
            if type.hasPrefix("String") { return "\"\(inner)\"" }
            return inner.isEmpty ? nil : inner
        }
        if value.hasPrefix("\"") { return value }
        return "dbgenerated(\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\")"
    }


    static func sql(_ schema: DBSchema, dialect: SchemaExportFormat) -> String {
        let enumNames = Set(schema.enums.map(\.name))
        var out = ""
        if dialect == .postgres {
            for item in schema.enums {
                let values = item.values.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ", ")
                out += "CREATE TYPE \(DBTypeMapping.quote(item.name, dialect)) AS ENUM (\(values));\n\n"
            }
        }
        for table in schema.tables where table.kind == .table || table.kind == .collection {
            var lines: [String] = []
            let compositeKey = table.primaryKey.count > 1
            for column in table.columns {
                var line = "  \(DBTypeMapping.quote(column.name, dialect)) "
                let autoIncrement = column.defaultValue?.lowercased() == "autoincrement()"
                if autoIncrement && dialect == .postgres {
                    line += DBTypeMapping.prisma(column.type) == "BigInt" ? "BIGSERIAL" : "SERIAL"
                } else {
                    line += DBTypeMapping.sql(column.type, dialect: dialect, enums: enumNames) + (column.isList && dialect == .postgres ? "[]" : "")
                }
                if !column.isNullable || column.isPrimaryKey { line += " NOT NULL" }
                if autoIncrement && dialect == .mysql { line += " AUTO_INCREMENT" }
                if let value = column.defaultValue, !autoIncrement, let rendered = sqlDefault(value, isEnum: enumNames.contains(column.type)) { line += " DEFAULT \(rendered)" }
                if column.isPrimaryKey, !compositeKey { line += " PRIMARY KEY" }
                if column.isUnique, !column.isPrimaryKey { line += " UNIQUE" }
                lines.append(line)
            }
            if compositeKey {
                lines.append("  PRIMARY KEY (\(table.primaryKey.map { DBTypeMapping.quote($0, dialect) }.joined(separator: ", ")))")
            }
            out += "CREATE TABLE \(DBTypeMapping.quote(table.name, dialect)) (\n\(lines.joined(separator: ",\n"))\n);\n\n"
        }
        for relation in schema.relations where relation.kind == .manyToOne || relation.kind == .oneToOne {
            guard !relation.fromColumns.isEmpty, let target = schema.table(relation.to) else { continue }
            let toColumns = relation.toColumns.isEmpty ? target.primaryKey : relation.toColumns
            guard !toColumns.isEmpty else { continue }
            let name = relation.name ?? "\(identifier(relation.from))_\(relation.fromColumns.joined(separator: "_"))_fkey"
            var line = "ALTER TABLE \(DBTypeMapping.quote(relation.from, dialect)) ADD CONSTRAINT \(DBTypeMapping.quote(name, dialect)) "
            line += "FOREIGN KEY (\(relation.fromColumns.map { DBTypeMapping.quote($0, dialect) }.joined(separator: ", "))) "
            line += "REFERENCES \(DBTypeMapping.quote(relation.to, dialect)) (\(toColumns.map { DBTypeMapping.quote($0, dialect) }.joined(separator: ", ")))"
            if let onDelete = relation.onDelete { line += " ON DELETE \(sqlAction(onDelete))" }
            out += line + ";\n"
        }
        for relation in schema.relations where relation.kind == .manyToMany {
            guard let left = schema.table(relation.from), let right = schema.table(relation.to),
                  left.primaryKey.count == 1, right.primaryKey.count == 1,
                  let leftKey = left.column(left.primaryKey[0]), let rightKey = right.column(right.primaryKey[0]) else { continue }
            let join = "_\(identifier(relation.from))To\(identifier(relation.to))"
            out += "\nCREATE TABLE \(DBTypeMapping.quote(join, dialect)) (\n"
            out += "  \"A\" \(DBTypeMapping.sql(leftKey.type, dialect: dialect)) NOT NULL REFERENCES \(DBTypeMapping.quote(relation.from, dialect)) (\(DBTypeMapping.quote(leftKey.name, dialect))) ON DELETE CASCADE,\n"
            out += "  \"B\" \(DBTypeMapping.sql(rightKey.type, dialect: dialect)) NOT NULL REFERENCES \(DBTypeMapping.quote(relation.to, dialect)) (\(DBTypeMapping.quote(rightKey.name, dialect))) ON DELETE CASCADE,\n"
            out += "  PRIMARY KEY (\"A\", \"B\")\n);\n"
            if dialect == .mysql { out = out.replacingOccurrences(of: "\"A\"", with: "`A`").replacingOccurrences(of: "\"B\"", with: "`B`") }
        }
        return out
    }

    static func sqlAction(_ value: String) -> String {
        switch value {
        case "Cascade": return "CASCADE"
        case "SetNull": return "SET NULL"
        case "SetDefault": return "SET DEFAULT"
        case "Restrict": return "RESTRICT"
        case "NoAction": return "NO ACTION"
        default: return value.uppercased()
        }
    }

    static func enumMember(_ raw: String) -> String? {
        let value = raw.components(separatedBy: "::").first?.trimmingCharacters(in: .whitespaces) ?? raw
        let member = SchemaText.unquote(value)
        guard !member.isEmpty, member.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return member
    }

    static func sqlDefault(_ raw: String, isEnum: Bool = false) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if isEnum, let member = enumMember(value) { return "'\(member)'" }
        switch value {
        case "now()": return "CURRENT_TIMESTAMP"
        case "uuid()", "cuid()": return nil
        case "autoincrement()", "auto()": return nil
        default: break
        }
        if value.hasPrefix("dbgenerated("), value.hasSuffix(")") {
            return SchemaText.unquote(String(value.dropFirst(12).dropLast()))
        }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return "'\(value.dropFirst().dropLast().replacingOccurrences(of: "'", with: "''"))'"
        }
        return value
    }


    static func dbml(_ schema: DBSchema) -> String {
        var out = ""
        if schema.dialect != .unknown { out += "Project schema {\n  database_type: '\(schema.dialect.title)'\n}\n\n" }
        for table in schema.tables {
            out += "Table \(dbmlName(table.name)) {\n"
            for column in table.columns {
                var settings: [String] = []
                if column.isPrimaryKey { settings.append("pk") }
                if column.defaultValue?.lowercased() == "autoincrement()" { settings.append("increment") }
                if !column.isNullable, !column.isPrimaryKey { settings.append("not null") }
                if column.isUnique, !column.isPrimaryKey { settings.append("unique") }
                if let value = column.defaultValue, value.lowercased() != "autoincrement()" {
                    settings.append("default: `\(value.replacingOccurrences(of: "`", with: "'"))`")
                }
                if let comment = column.comment { settings.append("note: '\(comment.replacingOccurrences(of: "'", with: "\\'"))'") }
                let type = column.type.contains(" ") || column.type.contains("(") && column.type.contains("\"") ? "\"\(column.type)\"" : column.type
                out += "  \(dbmlName(column.name)) \(type)\(column.isList ? "[]" : "")"
                out += settings.isEmpty ? "\n" : " [\(settings.joined(separator: ", "))]\n"
            }
            if let comment = table.comment { out += "  Note: '\(comment.replacingOccurrences(of: "'", with: "\\'"))'\n" }
            out += "}\n\n"
        }
        for item in schema.enums {
            out += "Enum \(dbmlName(item.name)) {\n"
            for value in item.values { out += "  \(dbmlName(value))\n" }
            out += "}\n\n"
        }
        for relation in schema.relations where relation.kind != .embedded {
            let op: String
            switch relation.kind {
            case .oneToOne: op = "-"
            case .manyToMany: op = "<>"
            default: op = ">"
            }
            let left = relation.fromColumns.isEmpty ? (schema.table(relation.from)?.primaryKey ?? []) : relation.fromColumns
            let right = relation.toColumns.isEmpty ? (schema.table(relation.to)?.primaryKey ?? []) : relation.toColumns
            guard !left.isEmpty, !right.isEmpty else { continue }
            out += "Ref: \(endpoint(relation.from, left)) \(op) \(endpoint(relation.to, right))\n"
        }
        return out
    }

    static func dbmlName(_ name: String) -> String {
        let simple = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return simple ? name : "\"\(name)\""
    }

    static func endpoint(_ table: String, _ columns: [String]) -> String {
        columns.count == 1
            ? "\(dbmlName(table)).\(dbmlName(columns[0]))"
            : "\(dbmlName(table)).(\(columns.map(dbmlName).joined(separator: ", ")))"
    }
}
