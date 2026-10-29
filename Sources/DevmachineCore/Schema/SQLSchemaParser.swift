import Foundation

public enum SQLSchemaParser {
    public static func parse(files: [String], dialect: DBSchema.Dialect? = nil) -> DBSchema {
        var builder = Builder()
        for file in files {
            for statement in statements(in: file) {
                builder.apply(statement)
            }
        }
        return builder.schema(dialect: dialect ?? guessDialect(files.joined(separator: "\n")))
    }

    public static func parse(_ text: String, dialect: DBSchema.Dialect? = nil) -> DBSchema {
        parse(files: [text], dialect: dialect)
    }

    static func guessDialect(_ text: String) -> DBSchema.Dialect {
        let lower = text.lowercased()
        if lower.contains("auto_increment") || lower.contains("engine=") || lower.contains("`") { return .mysql }
        if lower.contains("autoincrement") && !lower.contains("serial") { return .sqlite }
        if lower.contains("nvarchar") || lower.contains("identity(") || lower.contains("[dbo]") { return .sqlserver }
        if lower.contains("serial") || lower.contains("timestamptz") || lower.contains("jsonb")
            || lower.contains("create type") || lower.contains("public.") || lower.contains("uuid") {
            return .postgres
        }
        return .unknown
    }


    static func statements(in text: String) -> [String] {
        let clean = SchemaText.stripComments(text, dashes: true)
        var statements: [String] = []
        var current = ""
        let chars = Array(clean)
        var index = 0
        var quote: Character?
        var dollarTag: String?
        while index < chars.count {
            let char = chars[index]
            if let tag = dollarTag {
                current.append(char)
                if char == "$", current.hasSuffix(tag), current.count > tag.count {
                    dollarTag = nil
                }
                index += 1
                continue
            }
            if let open = quote {
                current.append(char)
                if char == open { quote = nil }
                index += 1
                continue
            }
            if char == "'" || char == "\"" || char == "`" {
                quote = char
            } else if char == "$" {
                var end = index + 1
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
                if end < chars.count, chars[end] == "$" {
                    let tag = String(chars[index...end])
                    current += tag
                    dollarTag = tag
                    index = end + 1
                    continue
                }
            } else if char == ";" {
                statements.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(char)
            index += 1
        }
        statements.append(current)
        return statements
            .map { SchemaText.collapseWhitespace($0) }
            .filter { !$0.isEmpty }
    }


    private static let defaultSchemas: Set<String> = ["public", "main", "dbo"]

    static func tableName(_ raw: String) -> String {
        let parts = splitQualified(raw)
        guard let last = parts.last else { return raw }
        if parts.count >= 2, !defaultSchemas.contains(parts[parts.count - 2].lowercased()) {
            return parts[parts.count - 2] + "." + last
        }
        return last
    }

    private static func splitQualified(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for char in raw {
            if let q = quote {
                if char == q || (q == "[" && char == "]") { quote = nil } else { current.append(char) }
                continue
            }
            switch char {
            case "\"", "`": quote = char
            case "[": quote = "["
            case ".":
                parts.append(current)
                current = ""
            default: current.append(char)
            }
        }
        parts.append(current)
        return parts.filter { !$0.isEmpty }
    }

    struct ForeignKey {
        var constraint: String?
        var table: String
        var columns: [String]
        var refTable: String
        var refColumns: [String]
        var onDelete: String?
    }

    struct Builder {
        var tables: [DBTable] = []
        var enums: [DBEnum] = []
        var foreignKeys: [ForeignKey] = []
        var uniqueByName: [String: (table: String, column: String)] = [:]

        func index(of table: String) -> Int? { tables.firstIndex { $0.name.lowercased() == table.lowercased() } }

        mutating func apply(_ statement: String) {
            let lower = statement.lowercased()
            if lower.hasPrefix("create") {
                if let match = Regex.createTable.firstMatch(statement) {
                    createTable(match, statement: statement)
                } else if let match = Regex.createEnum.firstMatch(statement) {
                    let values = SchemaText.splitTopLevel(match[2]).map(SchemaText.unquote)
                    let name = tableName(match[1])
                    enums.removeAll { $0.name == name }
                    enums.append(DBEnum(name: name, values: values))
                } else if let match = Regex.createView.firstMatch(statement) {
                    let name = tableName(match[1])
                    if index(of: name) == nil { tables.append(DBTable(name: name, kind: .view)) }
                } else if let match = Regex.createUniqueIndex.firstMatch(statement) {
                    let columns = SchemaText.nameList("(" + match[3] + ")")
                    let table = tableName(match[2])
                    if columns.count == 1, let t = index(of: table), let c = columnIndex(t, columns[0]) {
                        tables[t].columns[c].isUnique = true
                        uniqueByName[SchemaText.unquote(match[1]).lowercased()] = (tables[t].name, columns[0])
                    }
                }
            } else if lower.hasPrefix("alter table") {
                alterTable(statement)
            } else if lower.hasPrefix("alter type"), let match = Regex.alterTypeAddValue.firstMatch(statement) {
                let name = tableName(match[1])
                if let e = enums.firstIndex(where: { $0.name == name }) {
                    enums[e].values.append(SchemaText.unquote(match[2]))
                }
            } else if lower.hasPrefix("drop table"), let match = Regex.dropTable.firstMatch(statement) {
                for raw in SchemaText.splitTopLevel(match[1]) {
                    let name = tableName(raw.split(separator: " ").first.map(String.init) ?? raw)
                    tables.removeAll { $0.name.lowercased() == name.lowercased() }
                    foreignKeys.removeAll { $0.table.lowercased() == name.lowercased() }
                }
            } else if lower.hasPrefix("drop type"), let match = Regex.dropType.firstMatch(statement) {
                let name = tableName(match[1])
                enums.removeAll { $0.name == name }
            } else if lower.hasPrefix("drop index"), let match = Regex.dropIndex.firstMatch(statement) {
                dropUnique(named: match[1])
            } else if lower.hasPrefix("drop view"), let match = Regex.dropView.firstMatch(statement) {
                let name = tableName(match[1])
                tables.removeAll { $0.kind == .view && $0.name.lowercased() == name.lowercased() }
            }
        }

        func columnIndex(_ table: Int, _ column: String) -> Int? {
            tables[table].columns.firstIndex { $0.name.lowercased() == column.lowercased() }
        }

        mutating func createTable(_ match: Regex.Match, statement: String) {
            let name = tableName(match[1])
            let chars = Array(statement)
            guard let open = chars.firstIndex(of: "("), let body = SchemaText.balanced(chars, from: open) else {
                if index(of: name) == nil { tables.append(DBTable(name: name)) }
                return
            }
            tables.removeAll { $0.name.lowercased() == name.lowercased() }
            foreignKeys.removeAll { $0.table.lowercased() == name.lowercased() }
            tables.append(DBTable(name: name))
            for definition in SchemaText.splitTopLevel(body.inner) {
                addDefinition(definition, to: name)
            }
        }

        mutating func addDefinition(_ definition: String, to table: String) {
            if SQLSchemaParser.isConstraint(definition) {
                addConstraint(definition, to: table)
            } else {
                addColumn(definition, to: table)
            }
        }

        mutating func addColumn(_ definition: String, to table: String) {
            guard let t = index(of: table) else { return }
            let tokens = tokenize(definition)
            guard tokens.count >= 1 else { return }
            let name = SchemaText.unquote(tokens[0])
            var typeTokens: [String] = []
            var cursor = 1
            let stopWords: Set<String> = [
                "not", "null", "primary", "unique", "default", "references", "check", "constraint", "generated",
                "auto_increment", "autoincrement", "identity", "collate", "comment", "on", "as",
            ]
            while cursor < tokens.count, !stopWords.contains(tokens[cursor].lowercased()) {
                typeTokens.append(tokens[cursor])
                cursor += 1
            }
            var column = DBColumn(name: name, type: typeTokens.joined(separator: " "), isNullable: true)
            if column.type.hasSuffix("[]") {
                column.isList = true
                column.type.removeLast(2)
            }
            let rest = tokens[cursor...].map { $0 }
            let restLower = rest.map { $0.lowercased() }
            var i = 0
            var inlineReference: ForeignKey?
            while i < rest.count {
                switch restLower[i] {
                case "not" where i + 1 < rest.count && restLower[i + 1] == "null":
                    column.isNullable = false
                    i += 1
                case "primary":
                    column.isPrimaryKey = true
                    column.isNullable = false
                case "unique":
                    column.isUnique = true
                case "default" where i + 1 < rest.count:
                    column.defaultValue = rest[i + 1]
                    i += 1
                case "auto_increment", "autoincrement", "identity":
                    column.defaultValue = column.defaultValue ?? "autoincrement()"
                case "generated":
                    if restLower[(i + 1)...].contains("identity") {
                        column.defaultValue = column.defaultValue ?? "autoincrement()"
                    }
                case "references" where i + 1 < rest.count:
                    var refTable = rest[i + 1]
                    var refColumns: [String] = []
                    if let paren = refTable.firstIndex(of: "(") {
                        refColumns = SchemaText.nameList(String(refTable[paren...]))
                        refTable = String(refTable[..<paren])
                    } else if i + 2 < rest.count, rest[i + 2].hasPrefix("(") {
                        refColumns = SchemaText.nameList(rest[i + 2])
                        i += 1
                    }
                    inlineReference = ForeignKey(
                        constraint: nil, table: tables[t].name, columns: [name], refTable: tableName(refTable),
                        refColumns: refColumns, onDelete: onDelete(restLower[i...].joined(separator: " ")))
                    i += 1
                default:
                    break
                }
                i += 1
            }
            if column.type.lowercased().contains("serial") { column.defaultValue = column.defaultValue ?? "autoincrement()" }
            tables[t].columns.removeAll { $0.name.lowercased() == name.lowercased() }
            tables[t].columns.append(column)
            if let inlineReference { foreignKeys.append(inlineReference) }
        }

        mutating func addConstraint(_ definition: String, to table: String) {
            guard let t = index(of: table) else { return }
            var text = definition
            var constraintName: String?
            if let match = Regex.constraintName.firstMatch(text) {
                constraintName = SchemaText.unquote(match[1])
                text = match[2]
            }
            let lower = text.lowercased()
            if lower.hasPrefix("primary key"), let list = firstParenthesized(text) {
                let names = SchemaText.nameList(list)
                for index in tables[t].columns.indices where names.contains(where: {
                    $0.lowercased() == tables[t].columns[index].name.lowercased()
                }) {
                    tables[t].columns[index].isPrimaryKey = true
                    tables[t].columns[index].isNullable = false
                }
            } else if lower.hasPrefix("foreign key"), let match = Regex.foreignKey.firstMatch(text) {
                foreignKeys.append(ForeignKey(
                    constraint: constraintName, table: tables[t].name,
                    columns: SchemaText.nameList("(" + match[1] + ")"),
                    refTable: tableName(match[2]),
                    refColumns: match[3].isEmpty ? [] : SchemaText.nameList("(" + match[3] + ")"),
                    onDelete: onDelete(lower)))
            } else if lower.hasPrefix("unique"), let list = firstParenthesized(text) {
                let names = SchemaText.nameList(list)
                if names.count == 1, let c = columnIndex(t, names[0]) {
                    tables[t].columns[c].isUnique = true
                    if let constraintName {
                        uniqueByName[constraintName.lowercased()] = (tables[t].name, tables[t].columns[c].name)
                    }
                }
            }
        }

        mutating func alterTable(_ statement: String) {
            guard let match = Regex.alterTable.firstMatch(statement) else { return }
            let table = tableName(match[1])
            for action in SchemaText.splitTopLevel(match[2]) {
                let lower = action.lowercased()
                if let rename = Regex.renameTo.firstMatch(action), !lower.hasPrefix("rename column") {
                    let newName = tableName(rename[1])
                    guard let t = index(of: table) else { continue }
                    let old = tables[t].name
                    tables[t].name = newName
                    for k in foreignKeys.indices {
                        if foreignKeys[k].table == old { foreignKeys[k].table = newName }
                        if foreignKeys[k].refTable.lowercased() == old.lowercased() { foreignKeys[k].refTable = newName }
                    }
                } else if let rename = Regex.renameColumn.firstMatch(action) {
                    let old = SchemaText.unquote(rename[1])
                    let new = SchemaText.unquote(rename[2])
                    guard let t = index(of: table), let c = columnIndex(t, old) else { continue }
                    tables[t].columns[c].name = new
                    let tableName = tables[t].name
                    for k in foreignKeys.indices {
                        if foreignKeys[k].table == tableName {
                            foreignKeys[k].columns = foreignKeys[k].columns.map { $0.lowercased() == old.lowercased() ? new : $0 }
                        }
                        if foreignKeys[k].refTable == tableName {
                            foreignKeys[k].refColumns = foreignKeys[k].refColumns.map { $0.lowercased() == old.lowercased() ? new : $0 }
                        }
                    }
                } else if lower.hasPrefix("add") {
                    var definition = String(action.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    for word in ["column if not exists ", "column ", "if not exists "] where definition.lowercased().hasPrefix(word) {
                        definition = String(definition.dropFirst(word.count))
                    }
                    addDefinition(definition, to: table)
                } else if lower.hasPrefix("drop constraint") || lower.hasPrefix("drop foreign key")
                    || lower.hasPrefix("drop index") || lower.hasPrefix("drop key") {
                    let words = action.split(separator: " ").map(String.init)
                    guard let name = words.last.map(SchemaText.unquote) else { continue }
                    foreignKeys.removeAll { $0.constraint?.lowercased() == name.lowercased() }
                    dropUnique(named: name)
                } else if lower.hasPrefix("drop") {
                    let words = action.split(separator: " ").map(String.init)
                        .filter { !["drop", "column", "if", "exists", "cascade", "restrict"].contains($0.lowercased()) }
                    guard let column = words.first.map(SchemaText.unquote), let t = index(of: table) else { continue }
                    tables[t].columns.removeAll { $0.name.lowercased() == column.lowercased() }
                    let name = tables[t].name
                    foreignKeys.removeAll { $0.table == name && $0.columns.contains { $0.lowercased() == column.lowercased() } }
                } else if lower.hasPrefix("alter") || lower.hasPrefix("modify") || lower.hasPrefix("change") {
                    alterColumn(action, table: table)
                }
            }
        }

        mutating func alterColumn(_ action: String, table: String) {
            guard let t = index(of: table) else { return }
            var tokens = tokenize(action)
            let lowerFirst = tokens.first?.lowercased()
            if lowerFirst == "alter" || lowerFirst == "modify" || lowerFirst == "change" { tokens.removeFirst() }
            if tokens.first?.lowercased() == "column" { tokens.removeFirst() }
            guard let first = tokens.first else { return }
            let column = SchemaText.unquote(first)
            guard let c = columnIndex(t, column) else { return }
            let rest = tokens.dropFirst().map { $0.lowercased() }.joined(separator: " ")
            if lowerFirst == "modify" || lowerFirst == "change" {
                let definition = lowerFirst == "change" ? tokens.dropFirst().joined(separator: " ") : tokens.joined(separator: " ")
                tables[t].columns.remove(at: c)
                addColumn(definition, to: tables[t].name)
                return
            }
            if rest.hasPrefix("set not null") {
                tables[t].columns[c].isNullable = false
            } else if rest.hasPrefix("drop not null") {
                tables[t].columns[c].isNullable = true
            } else if rest.hasPrefix("set default") {
                tables[t].columns[c].defaultValue = tokens.dropFirst(3).joined(separator: " ")
            } else if rest.hasPrefix("drop default") {
                tables[t].columns[c].defaultValue = nil
            } else if rest.hasPrefix("set data type") || rest.hasPrefix("type") {
                let skip = rest.hasPrefix("type") ? 2 : 4
                let typeTokens = tokens.dropFirst(skip).prefix { !["using", "collate"].contains($0.lowercased()) }
                tables[t].columns[c].type = typeTokens.joined(separator: " ")
            }
        }

        mutating func dropUnique(named raw: String) {
            let name = SchemaText.unquote(raw.split(separator: ".").last.map(String.init) ?? raw).lowercased()
            guard let unique = uniqueByName.removeValue(forKey: name),
                  let t = index(of: unique.table), let c = columnIndex(t, unique.column) else { return }
            tables[t].columns[c].isUnique = false
        }

        func onDelete(_ lower: String) -> String? {
            guard let range = lower.range(of: "on delete ") else { return nil }
            let tail = lower[range.upperBound...]
            for action in ["cascade", "set null", "set default", "restrict", "no action"] where tail.hasPrefix(action) {
                return action.uppercased()
            }
            return nil
        }

        func schema(dialect: DBSchema.Dialect) -> DBSchema {
            var relations: [DBRelation] = []
            var seen = Set<String>()
            for key in foreignKeys {
                guard let from = index(of: key.table), let to = index(of: key.refTable) else { continue }
                let fromTable = tables[from]
                let toTable = tables[to]
                let refColumns = key.refColumns.isEmpty ? toTable.primaryKey : key.refColumns
                let columns = key.columns.compactMap { name in fromTable.columns.first { $0.name.lowercased() == name.lowercased() } }
                guard !columns.isEmpty else { continue }
                let isUnique = (columns.count == 1 && (columns[0].isUnique || (columns[0].isPrimaryKey && fromTable.primaryKey.count == 1)))
                    || Set(fromTable.primaryKey) == Set(columns.map(\.name))
                let relation = DBRelation(
                    name: key.constraint, from: fromTable.name, fromColumns: columns.map(\.name), to: toTable.name,
                    toColumns: refColumns.map { name in toTable.columns.first { $0.name.lowercased() == name.lowercased() }?.name ?? name },
                    kind: isUnique ? .oneToOne : .manyToOne,
                    isOptional: columns.contains(where: \.isNullable), onDelete: key.onDelete)
                if seen.insert(relation.id).inserted { relations.append(relation) }
            }
            return DBSchema(dialect: dialect, tables: tables, enums: enums, relations: relations)
        }
    }

    static func isConstraint(_ definition: String) -> Bool {
        let lower = definition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let first = String(lower.prefix { !$0.isWhitespace && $0 != "(" })
        let rest = lower.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch first {
        case "constraint":
            return true
        case "primary", "foreign":
            return rest.hasPrefix("key")
        case "check":
            return rest.hasPrefix("(")
        case "exclude":
            return rest.hasPrefix("(") || rest.hasPrefix("using")
        case "unique", "key", "index", "fulltext", "spatial":
            let tokens = tokenize(rest)
            guard let next = tokens.first, !rest.hasPrefix("(") else { return true }
            if ["key", "index", "nulls"].contains(next) { return true }
            if tokens.count > 1, tokens[1].hasPrefix("(") { return true }
            guard let open = next.firstIndex(of: "(") else { return false }
            return DBTypeMapping.prisma(String(next[..<open])).hasPrefix("Unsupported")
        default:
            return false
        }
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
                index += 1
            } else if char == "(", let group = SchemaText.balanced(chars, from: index) {
                current += "(" + group.inner + ")"
                index = group.end
            } else if char == "'" || char == "\"" || char == "`" || char == "[" {
                let close: Character = char == "[" ? "]" : char
                var end = index + 1
                while end < chars.count, chars[end] != close { end += 1 }
                current += String(chars[index...min(end, chars.count - 1)])
                index = end + 1
            } else {
                current.append(char)
                index += 1
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func firstParenthesized(_ text: String) -> String? {
        let chars = Array(text)
        guard let open = chars.firstIndex(of: "("), let group = SchemaText.balanced(chars, from: open) else { return nil }
        return "(" + group.inner + ")"
    }


    enum Regex {
        struct Match {
            let groups: [String]
            subscript(_ index: Int) -> String { index < groups.count ? groups[index] : "" }
        }

        struct Pattern: @unchecked Sendable {
            let regex: NSRegularExpression

            init(_ pattern: String) {
                regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            }

            func firstMatch(_ text: String) -> Match? {
                let range = NSRange(text.startIndex..., in: text)
                guard let result = regex.firstMatch(in: text, range: range) else { return nil }
                let groups = (0..<result.numberOfRanges).map { index -> String in
                    guard let r = Range(result.range(at: index), in: text) else { return "" }
                    return String(text[r])
                }
                return Match(groups: groups)
            }
        }

        static let identifier = #"((?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[\w$]+)(?:\s*\.\s*(?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[\w$]+))*)"#
        static let createTable = Pattern(
            #"^create\s+(?:or\s+replace\s+)?(?:(?:global|local)\s+)?(?:temp(?:orary)?\s+|unlogged\s+|virtual\s+)?table\s+(?:if\s+not\s+exists\s+)?"# + identifier)
        static let createEnum = Pattern(#"^create\s+type\s+"# + identifier + #"\s+as\s+enum\s*\((.*)\)"#)
        static let createView = Pattern(#"^create\s+(?:or\s+replace\s+)?(?:materialized\s+)?view\s+(?:if\s+not\s+exists\s+)?"# + identifier)
        static let createUniqueIndex = Pattern(
            #"^create\s+unique\s+index\s+(?:concurrently\s+)?(?:if\s+not\s+exists\s+)?"# + identifier + #"\s+on\s+(?:only\s+)?"# + identifier + #"(?:\s+using\s+\w+)?\s*\((.*)\)"#)
        static let alterTable = Pattern(#"^alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?"# + identifier + #"\s+(.*)$"#)
        static let alterTypeAddValue = Pattern(#"^alter\s+type\s+"# + identifier + #"\s+add\s+value\s+(?:if\s+not\s+exists\s+)?('[^']*')"#)
        static let dropTable = Pattern(#"^drop\s+table\s+(?:if\s+exists\s+)?(.*?)(?:\s+(?:cascade|restrict))?$"#)
        static let dropType = Pattern(#"^drop\s+type\s+(?:if\s+exists\s+)?"# + identifier)
        static let dropIndex = Pattern(#"^drop\s+index\s+(?:concurrently\s+)?(?:if\s+exists\s+)?"# + identifier)
        static let dropView = Pattern(#"^drop\s+(?:materialized\s+)?view\s+(?:if\s+exists\s+)?"# + identifier)
        static let constraintName = Pattern(#"^constraint\s+((?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[\w$]+))\s+(.*)$"#)
        static let foreignKey = Pattern(#"^foreign\s+key\s*\(([^)]*)\)\s*references\s+"# + identifier + #"\s*(?:\(([^)]*)\))?"#)
        static let renameTo = Pattern(#"^rename\s+to\s+"# + identifier)
        static let renameColumn = Pattern(#"^rename\s+(?:column\s+)?((?:"[^"]+"|`[^`]+`|[\w$]+))\s+to\s+((?:"[^"]+"|`[^`]+`|[\w$]+))"#)
    }
}
