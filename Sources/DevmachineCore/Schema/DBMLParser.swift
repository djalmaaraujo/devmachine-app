import Foundation

public enum DBMLParser {
    public static func parse(_ text: String) -> DBSchema {
        let clean = SchemaText.stripComments(text, slashes: true)
        let chars = Array(clean)
        var tables: [DBTable] = []
        var enums: [DBEnum] = []
        var refs: [(from: String, fromColumns: [String], to: String, toColumns: [String], op: String)] = []
        var dialect = DBSchema.Dialect.unknown
        var aliases: [String: String] = [:]

        var index = 0
        while index < chars.count {
            guard let brace = nextBrace(chars, from: index) else {
                parseInlineRefs(String(chars[index...]), into: &refs)
                break
            }
            let headerLines = String(chars[index..<brace]).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let body = SchemaText.balanced(chars, from: brace) else { break }
            index = body.end
            let lastHeader = SchemaText.collapseWhitespace(headerLines.last ?? "")
            parseInlineRefs(headerLines.dropLast().joined(separator: "\n"), into: &refs)
            let words = lastHeader.split(separator: " ").map(String.init)
            guard let keyword = words.first?.lowercased() else { continue }

            switch keyword {
            case "project":
                if let match = body.inner.range(of: #"database_type:\s*['"]([^'"]+)['"]"#, options: .regularExpression) {
                    let value = String(body.inner[match]).lowercased()
                    if value.contains("postgres") { dialect = .postgres }
                    else if value.contains("mysql") { dialect = .mysql }
                    else if value.contains("sqlite") { dialect = .sqlite }
                    else if value.contains("sql server") || value.contains("mssql") { dialect = .sqlserver }
                    else if value.contains("mongo") { dialect = .mongodb }
                }
            case "table":
                guard words.count >= 2 else { continue }
                let name = SQLSchemaParser.tableName(words[1])
                if let asIndex = words.firstIndex(where: { $0.lowercased() == "as" }), asIndex + 1 < words.count {
                    aliases[SchemaText.unquote(words[asIndex + 1])] = name
                }
                var table = DBTable(name: name)
                for line in tableLines(body.inner) {
                    guard let column = column(line, table: name, refs: &refs) else { continue }
                    table.columns.append(column)
                }
                if let note = note(in: body.inner) { table.comment = note }
                applyIndexes(body.inner, to: &table)
                tables.append(table)
            case "enum":
                guard words.count >= 2 else { continue }
                let values = body.inner.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { line -> String in
                        let head = line.components(separatedBy: "[").first ?? line
                        return SchemaText.unquote(head.trimmingCharacters(in: .whitespaces))
                    }
                enums.append(DBEnum(name: SQLSchemaParser.tableName(words[1]), values: values))
            case "ref":
                for line in body.inner.components(separatedBy: .newlines) {
                    parseRef(line, into: &refs)
                }
            default:
                break
            }
        }

        func resolve(_ name: String) -> String { aliases[name] ?? name }
        var relations: [DBRelation] = []
        for ref in refs {
            var from = (table: resolve(ref.from), columns: ref.fromColumns)
            var to = (table: resolve(ref.to), columns: ref.toColumns)
            if ref.op == "<" { swap(&from, &to) }
            guard let fromTable = tables.first(where: { $0.name == from.table }),
                  tables.contains(where: { $0.name == to.table }) else { continue }
            let kind: DBRelation.Kind
            switch ref.op {
            case "-": kind = .oneToOne
            case "<>": kind = .manyToMany
            default: kind = .manyToOne
            }
            let optional = from.columns.contains { fromTable.column($0)?.isNullable ?? false }
            relations.append(DBRelation(
                from: from.table, fromColumns: from.columns, to: to.table, toColumns: to.columns,
                kind: kind, isOptional: optional))
        }
        return DBSchema(dialect: dialect, tables: tables, enums: enums, relations: relations)
    }

    private static func nextBrace(_ chars: [Character], from start: Int) -> Int? {
        var quote: Character?
        var index = start
        while index < chars.count {
            let char = chars[index]
            if let q = quote {
                if char == q { quote = nil }
            } else if char == "'" || char == "\"" || char == "`" {
                quote = char
            } else if char == "{" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func tableLines(_ body: String) -> [String] {
        let chars = Array(body)
        var lines: [String] = []
        var current = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "{", let group = SchemaText.balanced(chars, from: index) {
                index = group.end
                current = ""
                continue
            }
            if char == "[", let group = SchemaText.balanced(chars, from: index) {
                current += "[" + group.inner + "]"
                index = group.end
                continue
            }
            if char == "'" || char == "\"" {
                var end = index + 1
                if index + 2 < chars.count, chars[index + 1] == char, chars[index + 2] == char {
                    end = index + 3
                    while end + 2 < chars.count, !(chars[end] == char && chars[end + 1] == char && chars[end + 2] == char) { end += 1 }
                    current += String(chars[index..<min(end + 3, chars.count)])
                    index = end + 3
                    continue
                }
                while end < chars.count, chars[end] != char { end += 1 }
                current += String(chars[index...min(end, chars.count - 1)])
                index = end + 1
                continue
            }
            if char == "\n" {
                lines.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index += 1
        }
        lines.append(current)
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func column(
        _ line: String, table: String,
        refs: inout [(from: String, fromColumns: [String], to: String, toColumns: [String], op: String)]
    ) -> DBColumn? {
        let lower = line.lowercased()
        if lower.hasPrefix("note") || lower.hasPrefix("indexes") { return nil }
        var head = line
        var settings = ""
        if let open = line.firstIndex(of: "["), line.hasSuffix("]") {
            head = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            settings = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
        }
        let parts = SQLSchemaParser.tokenize(head)
        guard parts.count >= 2 else { return nil }
        var column = DBColumn(name: SchemaText.unquote(parts[0]), type: SchemaText.unquote(parts[1...].joined(separator: " ")), isNullable: true)
        for setting in SchemaText.splitTopLevel(settings) {
            let key = setting.lowercased()
            switch key {
            case "pk", "primary key":
                column.isPrimaryKey = true
                column.isNullable = false
            case "not null": column.isNullable = false
            case "null": column.isNullable = true
            case "unique": column.isUnique = true
            case "increment": column.defaultValue = "autoincrement()"
            default:
                if key.hasPrefix("default:") {
                    column.defaultValue = setting.dropFirst(8).trimmingCharacters(in: .whitespaces)
                } else if key.hasPrefix("note:") {
                    column.comment = SchemaText.unquote(String(setting.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                } else if key.hasPrefix("ref:") {
                    parseRef("Ref: \(table).\(column.name) " + setting.dropFirst(4).trimmingCharacters(in: .whitespaces), into: &refs)
                }
            }
        }
        return column
    }

    private static func parseInlineRefs(
        _ text: String,
        into refs: inout [(from: String, fromColumns: [String], to: String, toColumns: [String], op: String)]
    ) {
        for line in text.components(separatedBy: .newlines) where line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("ref") {
            parseRef(line, into: &refs)
        }
    }

    private static func parseRef(
        _ line: String,
        into refs: inout [(from: String, fromColumns: [String], to: String, toColumns: [String], op: String)]
    ) {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("ref") {
            guard let colon = text.firstIndex(of: ":") else { return }
            text = String(text[text.index(after: colon)...])
        }
        if let bracket = text.firstIndex(of: "[") { text = String(text[..<bracket]) }
        for op in ["<>", ">", "<", "-"] {
            let sides = text.components(separatedBy: " \(op) ")
            guard sides.count == 2, let left = endpoint(sides[0]), let right = endpoint(sides[1]) else { continue }
            refs.append((left.table, left.columns, right.table, right.columns, op))
            return
        }
    }

    private static func endpoint(_ raw: String) -> (table: String, columns: [String])? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let open = text.firstIndex(of: "("), text.hasSuffix(")") {
            let table = String(text[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return (SQLSchemaParser.tableName(table), SchemaText.nameList(String(text[open...])))
        }
        guard let dot = text.lastIndex(of: ".") else { return nil }
        let table = SQLSchemaParser.tableName(String(text[..<dot]))
        return (table, [SchemaText.unquote(String(text[text.index(after: dot)...]))])
    }

    private static func note(in body: String) -> String? {
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("note:") {
                return SchemaText.unquote(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func applyIndexes(_ body: String, to table: inout DBTable) {
        let chars = Array(body)
        guard let range = body.range(of: "indexes", options: .caseInsensitive),
              let brace = body[range.upperBound...].firstIndex(of: "{") else { return }
        let offset = body.distance(from: body.startIndex, to: brace)
        guard let group = SchemaText.balanced(chars, from: offset) else { return }
        for line in group.inner.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")") else { continue }
            let names = SchemaText.nameList(String(trimmed[...close]))
            let settings = trimmed[trimmed.index(after: close)...].lowercased()
            if settings.contains("pk") {
                for index in table.columns.indices where names.contains(table.columns[index].name) {
                    table.columns[index].isPrimaryKey = true
                }
            } else if settings.contains("unique"), names.count == 1 {
                for index in table.columns.indices where table.columns[index].name == names[0] {
                    table.columns[index].isUnique = true
                }
            }
        }
    }
}
