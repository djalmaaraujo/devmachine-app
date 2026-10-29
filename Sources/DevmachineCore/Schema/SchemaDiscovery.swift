import Foundation

public struct SchemaFile: Equatable, Sendable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

public struct SchemaSource: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case prisma, sql, dbml, mongoose

        public var title: String {
            switch self {
            case .prisma: return "Prisma"
            case .sql: return "SQL"
            case .dbml: return "DBML"
            case .mongoose: return "Mongoose"
            }
        }

        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    public var id: String { kind.rawValue + ":" + location }
    public let kind: Kind
    public let location: String
    public let files: [SchemaFile]

    public init(kind: Kind, location: String, files: [SchemaFile]) {
        self.kind = kind
        self.location = location
        self.files = files
    }

    public var title: String {
        if files.count == 1, let file = files.first { return file.path }
        return "\(location) · \(files.count) \(kind.title) files"
    }

    public func parse() -> DBSchema {
        let schema: DBSchema
        switch kind {
        case .prisma: schema = PrismaSchemaParser.parse(files.map(\.text).joined(separator: "\n"))
        case .sql: schema = SQLSchemaParser.parse(files: files.map(\.text))
        case .dbml: schema = DBMLParser.parse(files.map(\.text).joined(separator: "\n"))
        case .mongoose: schema = MongooseSchemaParser.parse(files: files.map(\.text))
        }
        return schema.deduplicated()
    }
}

public enum SchemaDiscovery {
    public static let marker = "@@DMSCHEMA@@ "
    public static let maxFiles = 600
    public static let maxBytes = 24_000_000

    public static var command: String {
        let pruned = ["node_modules", ".git", ".next", ".nuxt", "dist", "build", "vendor", ".venv", "venv",
                      "target", ".worktrees", ".turbo", ".cache", "coverage", "Pods", ".expo", "out", ".svelte-kit", "__pycache__"]
            .map { "-name '\($0)'" }
            .joined(separator: " -o ")
        return """
        find . -maxdepth 7 \\( \(pruned) \\) -prune -o -type f \\( -name '*.prisma' -o -name '*.sql' -o -name '*.dbml' \
        -o \\( -path '*model*' \\( -name '*.js' -o -name '*.ts' -o -name '*.mjs' -o -name '*.cjs' \\) \\) \\) \
        -size -1024k -print 2>/dev/null | head -n \(maxFiles) | while IFS= read -r f; do \
        case "$f" in *.js|*.ts|*.mjs|*.cjs) grep -q 'Schema' "$f" 2>/dev/null || continue ;; esac; \
        printf '%s%s\\n' '\(marker)' "$f"; base64 < "$f"; done | head -c \(maxBytes)
        """
    }

    public static func command(in folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return command }
        return "cd \(FileUpload.shellQuoted(folder)) && " + command
    }

    public static func parseOutput(_ output: String) -> [SchemaFile] {
        var files: [SchemaFile] = []
        var path: String?
        var chunk = ""
        func flush() {
            guard let current = path else { return }
            let cleaned = chunk.filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: cleaned), let text = String(data: data, encoding: .utf8) {
                files.append(SchemaFile(path: normalize(current), text: text))
            }
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(marker) {
                flush()
                path = String(line.dropFirst(marker.count))
                chunk = ""
            } else {
                chunk += line
            }
        }
        flush()
        return files
    }

    static func normalize(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    public static func sources(from files: [SchemaFile]) -> [SchemaSource] {
        var prisma: [String: [SchemaFile]] = [:]
        var sql: [String: [SchemaFile]] = [:]
        var dbml: [SchemaFile] = []
        var mongoose: [SchemaFile] = []

        for file in files {
            let path = file.path
            let lower = path.lowercased()
            if lower.hasSuffix(".prisma") {
                prisma[directory(path), default: []].append(file)
            } else if lower.hasSuffix(".sql") {
                guard looksLikeDDL(file.text) else { continue }
                sql[sqlLocation(path), default: []].append(file)
            } else if lower.hasSuffix(".dbml") {
                dbml.append(file)
            } else if isMongoose(file.text) {
                mongoose.append(file)
            }
        }

        var sources: [SchemaSource] = []
        for (location, group) in prisma {
            let sorted = group.sorted { $0.path < $1.path }
            let standalone = sorted.filter { hasDatasource($0.text) }
            let groups: [(String, [SchemaFile])] = standalone.count > 1
                ? standalone.map { ($0.path, [$0]) } + [(location, sorted.filter { !hasDatasource($0.text) })]
                : [(location, sorted)]
            for (place, files) in groups where files.contains(where: declaresModels) {
                sources.append(SchemaSource(kind: .prisma, location: place.isEmpty ? "." : place, files: files))
            }
        }
        for (location, group) in sql {
            sources.append(SchemaSource(kind: .sql, location: location.isEmpty ? "." : location, files: group.sorted { $0.path < $1.path }))
        }
        for file in dbml {
            sources.append(SchemaSource(kind: .dbml, location: file.path, files: [file]))
        }
        if !mongoose.isEmpty {
            let location = commonDirectory(mongoose.map(\.path))
            sources.append(SchemaSource(kind: .mongoose, location: location.isEmpty ? "." : location, files: mongoose.sorted { $0.path < $1.path }))
        }
        return sources.sorted {
            if $0.kind != $1.kind { return $0.kind.rank < $1.kind.rank }
            return $0.location < $1.location
        }
    }

    static func directory(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func sqlLocation(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        if let index = components.lastIndex(where: { $0.lowercased() == "migrations" || $0.lowercased() == "migration" }) {
            return components[...index].joined(separator: "/")
        }
        return directory(path)
    }

    static func hasDatasource(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s*datasource\s+\w+\s*\{"#, options: .regularExpression) != nil
    }

    static func declaresModels(_ file: SchemaFile) -> Bool {
        file.text.contains("model ") || file.text.contains("enum ") || file.text.contains("type ")
    }

    static func looksLikeDDL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("create table") || lower.contains("alter table") || lower.contains("create type")
    }

    static func isMongoose(_ text: String) -> Bool {
        text.range(of: #"new\s+(?:mongoose\.)?Schema\s*(?:<[^>]*>)?\s*\("#, options: .regularExpression) != nil
    }

    static func commonDirectory(_ paths: [String]) -> String {
        let split = paths.map { directory($0).split(separator: "/").map(String.init) }
        guard var prefix = split.first else { return "" }
        for parts in split.dropFirst() {
            while !prefix.isEmpty, Array(parts.prefix(prefix.count)) != prefix { prefix.removeLast() }
        }
        return prefix.joined(separator: "/")
    }
}
