import Foundation

public enum MongooseSchemaParser {
    public static func parse(files: [String]) -> DBSchema {
        var tables: [DBTable] = []
        var relations: [DBRelation] = []
        for file in files {
            let found = schemas(in: SchemaText.stripComments(file, slashes: true))
            for schema in found {
                let names = Set([schema.table.name] + schema.embedded.map(\.name))
                tables.removeAll { names.contains($0.name) }
                tables.append(schema.table)
                tables += schema.embedded
                relations += schema.relations
            }
        }
        let names = Set(tables.map(\.name))
        relations = relations.filter { names.contains($0.to) }
        return DBSchema(dialect: .mongodb, tables: tables, enums: [], relations: relations)
    }

    struct Found {
        var table: DBTable
        var embedded: [DBTable]
        var relations: [DBRelation]
    }

    static func schemas(in text: String) -> [Found] {
        let chars = Array(text)
        let models = modelNames(in: text)
        var results: [Found] = []
        let pattern = try? NSRegularExpression(pattern: #"(?:const|let|var)\s+(\w+)\s*(?::\s*[\w<>.\s]+)?=\s*new\s+(?:mongoose\.)?Schema\s*(?:<[^>]*>)?\s*\("#)
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern?.matches(in: text, range: range) ?? [] {
            guard let variableRange = Range(match.range(at: 1), in: text),
                  let end = Range(match.range, in: text)?.upperBound else { continue }
            let variable = String(text[variableRange])
            var cursor = text.distance(from: text.startIndex, to: end)
            while cursor < chars.count, chars[cursor].isWhitespace { cursor += 1 }
            guard cursor < chars.count, chars[cursor] == "{", let body = SchemaText.balanced(chars, from: cursor) else { continue }
            var after = body.end
            while after < chars.count, chars[after].isWhitespace || chars[after] == "," { after += 1 }
            var options = ""
            if after < chars.count, chars[after] == "{", let group = SchemaText.balanced(chars, from: after) {
                options = group.inner
            }
            let name = models[variable] ?? modelName(fromVariable: variable)
            var found = Found(table: DBTable(name: name, kind: .collection), embedded: [], relations: [])
            found.table.columns.append(DBColumn(name: "_id", type: "ObjectId", isPrimaryKey: true))
            fields(body.inner, owner: name, into: &found)
            if options.range(of: #"timestamps\s*:\s*(true|\{)"#, options: .regularExpression) != nil {
                found.table.columns.append(DBColumn(name: "createdAt", type: "Date"))
                found.table.columns.append(DBColumn(name: "updatedAt", type: "Date"))
            }
            results.append(found)
        }
        return results
    }

    private static func fields(_ body: String, owner: String, into found: inout Found) {
        for entry in SchemaText.splitTopLevel(body) {
            let pieces = SchemaText.splitTopLevel(entry, on: ":")
            guard pieces.count >= 2 else { continue }
            let key = SchemaText.unquote(pieces[0])
            let value = pieces[1...].joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.first?.isLetter == true || key.first == "_" else { continue }
            let field = describe(value)
            var column = DBColumn(
                name: key, type: field.type, isNullable: !field.required, isList: field.isList,
                isUnique: field.unique, defaultValue: field.defaultValue)
            if let nested = field.nested {
                let embeddedName = owner + "." + key
                var embedded = Found(table: DBTable(name: embeddedName, kind: .embedded), embedded: [], relations: [])
                fields(nested, owner: embeddedName, into: &embedded)
                found.embedded.append(embedded.table)
                found.embedded += embedded.embedded
                found.relations += embedded.relations
                column.type = "Object"
                found.relations.append(DBRelation(
                    from: owner, fromColumns: [key], to: embeddedName, toColumns: [], kind: .embedded,
                    isOptional: column.isNullable))
            }
            if let ref = field.ref {
                found.relations.append(DBRelation(
                    from: owner, fromColumns: [key], to: ref, toColumns: ["_id"],
                    kind: field.isList ? .manyToMany : .manyToOne, isOptional: column.isNullable))
            }
            found.table.columns.append(column)
        }
    }

    struct FieldInfo {
        var type = "Mixed"
        var isList = false
        var required = false
        var unique = false
        var ref: String?
        var defaultValue: String?
        var nested: String?
    }

    static func describe(_ raw: String) -> FieldInfo {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var info = FieldInfo()
        if value.hasPrefix("[") {
            info.isList = true
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return info }
        }
        if value.hasPrefix("{") {
            let inner = String(value.dropFirst().dropLast())
            var properties: [String: String] = [:]
            for entry in SchemaText.splitTopLevel(inner) {
                let pieces = SchemaText.splitTopLevel(entry, on: ":")
                guard pieces.count >= 2 else { continue }
                properties[SchemaText.unquote(pieces[0])] = pieces[1...].joined(separator: ":")
            }
            guard let type = properties["type"] else {
                info.type = "Object"
                info.nested = inner
                return info
            }
            let base = describe(type)
            info.type = base.type
            info.isList = info.isList || base.isList
            info.nested = base.nested
            if let required = properties["required"] {
                info.required = !required.hasPrefix("false")
            }
            info.unique = properties["unique"]?.hasPrefix("true") ?? false
            info.ref = properties["ref"].map(SchemaText.unquote)
            info.defaultValue = properties["default"]
            return info
        }
        if value.hasPrefix("new ") || value.contains("Schema(") {
            info.type = "Object"
            return info
        }
        let last = value.split(separator: ".").last.map(String.init) ?? value
        info.type = last.isEmpty ? "Mixed" : last
        return info
    }

    static func modelNames(in text: String) -> [String: String] {
        var names: [String: String] = [:]
        guard let pattern = try? NSRegularExpression(pattern: #"model\s*(?:<[^>]*>)?\s*\(\s*['"]([\w.]+)['"]\s*,\s*(\w+)"#) else { return names }
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let model = Range(match.range(at: 1), in: text), let variable = Range(match.range(at: 2), in: text) else { continue }
            names[String(text[variable])] = String(text[model])
        }
        return names
    }

    static func modelName(fromVariable variable: String) -> String {
        var name = variable
        for suffix in ["Schema", "schema"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
