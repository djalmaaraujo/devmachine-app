import Foundation

public enum PrismaSchemaParser {
    public static func parse(_ text: String) -> DBSchema {
        let blocks = self.blocks(in: text)
        let modelNames = Set(blocks.filter { $0.keyword == "model" || $0.keyword == "view" }.map(\.name))
        let typeNames = Set(blocks.filter { $0.keyword == "type" }.map(\.name))

        var dialect = DBSchema.Dialect.unknown
        var enums: [DBEnum] = []
        var tables: [DBTable] = []
        var relationFields: [(model: String, field: Field)] = []

        for block in blocks {
            switch block.keyword {
            case "datasource":
                for line in block.lines {
                    let parts = line.text.split(separator: "=", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    if parts.count == 2, parts[0] == "provider" {
                        dialect = DBSchema.Dialect(prismaProvider: SchemaText.unquote(parts[1]))
                    }
                }
            case "enum":
                let values = block.lines.compactMap { line -> String? in
                    guard !line.text.hasPrefix("@@") else { return nil }
                    return line.text.split(whereSeparator: \.isWhitespace).first.map(String.init)
                }
                enums.append(DBEnum(name: block.name, values: values))
            case "model", "view", "type":
                var columns: [DBColumn] = []
                var blockAttributes: [Attribute] = []
                for line in block.lines {
                    if line.text.hasPrefix("@@") {
                        blockAttributes += attributes(in: line.text)
                        continue
                    }
                    guard let field = field(line.text, comment: line.comment) else { continue }
                    if modelNames.contains(field.baseType) {
                        relationFields.append((block.name, field))
                        continue
                    }
                    columns.append(DBColumn(
                        name: field.name, type: field.baseType, isNullable: field.isOptional,
                        isList: field.isList, isPrimaryKey: field.has("id"), isUnique: field.has("unique"),
                        defaultValue: field.attribute("default")?.arguments, comment: field.comment))
                }
                for attribute in blockAttributes {
                    let names = attribute.listArgument()
                    switch attribute.name {
                    case "@@id":
                        for index in columns.indices where names.contains(columns[index].name) {
                            columns[index].isPrimaryKey = true
                        }
                    case "@@unique" where names.count == 1:
                        for index in columns.indices where columns[index].name == names[0] {
                            columns[index].isUnique = true
                        }
                    default:
                        break
                    }
                }
                let kind: DBTable.Kind
                switch block.keyword {
                case "view": kind = .view
                case "type": kind = .embedded
                default: kind = dialect == .mongodb ? .collection : .table
                }
                tables.append(DBTable(name: block.name, kind: kind, columns: columns, comment: block.comment))
            default:
                break
            }
        }
        if dialect == .mongodb {
            for index in tables.indices where tables[index].kind == .table { tables[index].kind = .collection }
        }

        var relations = self.relations(relationFields, tables: tables)
        for table in tables {
            for column in table.columns where typeNames.contains(column.type) {
                relations.append(DBRelation(
                    from: table.name, fromColumns: [column.name], to: column.type, toColumns: [],
                    kind: .embedded, isOptional: column.isNullable))
            }
        }
        return DBSchema(dialect: dialect, tables: tables, enums: enums, relations: relations)
    }


    private static func relations(_ fields: [(model: String, field: Field)], tables: [DBTable]) -> [DBRelation] {
        var relations: [DBRelation] = []
        var pairedListFields = Set<String>()
        for (model, field) in fields {
            let relation = field.attribute("relation")
            let relationName = relation.flatMap { $0.namedArgument(nil).map(SchemaText.unquote) }
            let keyFields = relation?.namedArgument("fields").map(SchemaText.nameList) ?? []
            if !keyFields.isEmpty {
                let references = relation?.namedArgument("references").map(SchemaText.nameList) ?? []
                let table = tables.first { $0.name == model }
                let isUnique = isUniqueKey(keyFields, in: table)
                relations.append(DBRelation(
                    name: relationName, from: model, fromColumns: keyFields, to: field.baseType,
                    toColumns: references, kind: isUnique ? .oneToOne : .manyToOne,
                    isOptional: field.isOptional,
                    onDelete: relation?.namedArgument("onDelete")))
                continue
            }
            guard field.isList else { continue }
            let other = fields.first { candidate in
                candidate.model == field.baseType && candidate.field.baseType == model && candidate.field.isList
                    && (candidate.field.attribute("relation").flatMap { $0.namedArgument(nil).map(SchemaText.unquote) })
                        == relationName
                    && !(candidate.model == model && candidate.field.name == field.name)
            }
            guard let other else { continue }
            let key = [model + "." + field.name, other.model + "." + other.field.name].sorted().joined(separator: "|")
            guard !pairedListFields.contains(key) else { continue }
            pairedListFields.insert(key)
            relations.append(DBRelation(
                name: relationName, from: model, fromColumns: [], to: field.baseType, toColumns: [],
                kind: .manyToMany))
        }
        return relations
    }

    private static func isUniqueKey(_ keys: [String], in table: DBTable?) -> Bool {
        guard let table else { return false }
        if keys.count == 1, let column = table.column(keys[0]) {
            return column.isUnique || (column.isPrimaryKey && table.primaryKey.count == 1)
        }
        return Set(table.primaryKey) == Set(keys)
    }


    struct Line {
        let text: String
        let comment: String?
    }

    struct Block {
        let keyword: String
        let name: String
        var lines: [Line]
        let comment: String?
    }

    private static let blockKeywords: Set<String> = ["model", "enum", "view", "type", "datasource", "generator"]

    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        var docComment: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("///") {
                docComment.append(trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces))
                continue
            }
            let code = stripLineComment(trimmed)
            if code.isEmpty { continue }
            let comment = docComment.isEmpty ? nil : docComment.joined(separator: " ")
            docComment = []
            if var block = current {
                if code.hasPrefix("}") {
                    blocks.append(block)
                    current = nil
                } else {
                    block.lines.append(Line(text: code, comment: comment))
                    current = block
                }
                continue
            }
            let words = code.split(whereSeparator: { $0.isWhitespace || $0 == "{" }).map(String.init)
            guard words.count >= 2, blockKeywords.contains(words[0]), code.hasSuffix("{") else { continue }
            current = Block(keyword: words[0], name: words[1], lines: [], comment: comment)
        }
        return blocks
    }

    private static func stripLineComment(_ line: String) -> String {
        var inString = false
        var previous: Character?
        var result = ""
        for char in line {
            if char == "\"", previous != "\\" { inString.toggle() }
            if !inString, char == "/", previous == "/" {
                result.removeLast()
                break
            }
            result.append(char)
            previous = char
        }
        return result.trimmingCharacters(in: .whitespaces)
    }


    struct Field {
        let name: String
        let baseType: String
        let isOptional: Bool
        let isList: Bool
        let attributes: [Attribute]
        let comment: String?

        func has(_ name: String) -> Bool { attribute(name) != nil }
        func attribute(_ name: String) -> Attribute? { attributes.first { $0.name == "@" + name } }
    }

    struct Attribute {
        let name: String
        let arguments: String?

        func namedArgument(_ key: String?) -> String? {
            guard let arguments else { return nil }
            for part in SchemaText.splitTopLevel(arguments) {
                let pieces = SchemaText.splitTopLevel(part, on: ":")
                if let key {
                    if pieces.count == 2, pieces[0] == key { return pieces[1] }
                } else if pieces.count == 1 {
                    return pieces[0]
                }
            }
            return nil
        }

        func listArgument() -> [String] {
            guard let list = namedArgument("fields") ?? namedArgument(nil) else { return [] }
            return SchemaText.nameList(list)
        }
    }

    static func field(_ line: String, comment: String?) -> Field? {
        let chars = Array(line)
        var index = 0
        func skipSpaces() { while index < chars.count, chars[index].isWhitespace { index += 1 } }
        func word() -> String {
            let start = index
            while index < chars.count, !chars[index].isWhitespace, chars[index] != "@" { index += 1 }
            return String(chars[start..<index])
        }
        let name = word()
        guard !name.isEmpty, name.first?.isLetter == true || name.first == "_" else { return nil }
        skipSpaces()
        var type = ""
        while index < chars.count, !chars[index].isWhitespace, chars[index] != "@" {
            if chars[index] == "(", let group = SchemaText.balanced(chars, from: index) {
                type += "(" + group.inner + ")"
                index = group.end
            } else {
                type.append(chars[index])
                index += 1
            }
        }
        guard !type.isEmpty else { return nil }
        let isList = type.hasSuffix("[]")
        let isOptional = type.hasSuffix("?")
        var base = type
        if isList { base.removeLast(2) }
        if isOptional { base.removeLast() }
        let rest = String(chars[index...])
        return Field(
            name: name, baseType: base, isOptional: isOptional, isList: isList,
            attributes: attributes(in: rest), comment: comment)
    }

    static func attributes(in text: String) -> [Attribute] {
        let chars = Array(text)
        var result: [Attribute] = []
        var index = 0
        while index < chars.count {
            guard chars[index] == "@" else {
                index += 1
                continue
            }
            let start = index
            index += 1
            if index < chars.count, chars[index] == "@" { index += 1 }
            while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "." || chars[index] == "_" {
                index += 1
            }
            let name = String(chars[start..<index])
            var arguments: String?
            if index < chars.count, chars[index] == "(", let group = SchemaText.balanced(chars, from: index) {
                arguments = group.inner
                index = group.end
            }
            result.append(Attribute(name: name, arguments: arguments))
        }
        return result
    }
}
