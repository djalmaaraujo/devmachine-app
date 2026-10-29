import AppKit
import Foundation
import DevmachineCore

@MainActor
final class SchemaStore: ObservableObject {
    enum Status: Equatable {
        case idle, loading, loaded, empty
        case failed(DMErrorState)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var sources: [SchemaSource] = []
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var schema = DBSchema()
    @Published private(set) var original = DBSchema()
    @Published var positions: [String: SchemaPoint] = [:]
    @Published var selectedTable: String?
    @Published var isModeling = false
    @Published var editError: String?
    @Published private(set) var fitRequest = 0

    let metrics = SchemaLayout.Metrics()
    private let host: HostRunner
    private let demo: Bool
    private var target: CommandTarget?
    private var folder: String?
    private var savedPositions: [String: [String: SchemaPoint]] = [:]
    private var parsed: [String: DBSchema] = [:]

    init(host: HostRunner = HostRunner(), demo: Bool = DemoMode.isActive) {
        self.host = host
        self.demo = demo
    }

    var isEdited: Bool { schema != original }
    var selectedSource: SchemaSource? { sources.first { $0.id == selectedSourceID } }

    func load(_ target: CommandTarget, folder: String? = nil) {
        guard self.target != target || self.folder != folder || status == .idle else { return }
        self.target = target
        self.folder = folder
        refresh()
    }

    func refresh() {
        guard let target else { return }
        if demo {
            apply(SchemaStore.read(SchemaDemo.files))
            return
        }
        status = .loading
        let host = self.host
        let command = SchemaDiscovery.command(in: folder)
        Task.detached {
            let result = Result { try host.runCapturing(target, command) }
            let files = (try? result.get()).map { SchemaDiscovery.parseOutput($0.stdout) } ?? []
            let found = SchemaStore.read(files)
            await MainActor.run {
                guard self.target == target else { return }
                switch result {
                case .success(let output) where output.exitCode != 0 && files.isEmpty:
                    self.status = .failed(DMErrorState(
                        title: "Couldn't look for schema files",
                        message: output.stderr.isEmpty ? "exit \(output.exitCode)" : output.stderr))
                case .failure(let error):
                    self.status = .failed(DMErrorState(title: "Couldn't look for schema files", message: "\(error)"))
                default:
                    self.apply(found)
                }
            }
        }
    }

    nonisolated static func read(_ files: [SchemaFile]) -> (sources: [SchemaSource], schemas: [String: DBSchema]) {
        let sources = SchemaDiscovery.sources(from: files)
        return (sources, Dictionary(sources.map { ($0.id, $0.parse()) }, uniquingKeysWith: { _, last in last }))
    }

    private func apply(_ found: (sources: [SchemaSource], schemas: [String: DBSchema])) {
        sources = found.sources
        parsed = found.schemas
        guard !sources.isEmpty else {
            status = .empty
            schema = DBSchema()
            original = schema
            return
        }
        let keep = sources.contains { $0.id == selectedSourceID } ? selectedSourceID : sources.first?.id
        selectSource(keep, force: true)
    }

    func selectSource(_ id: String?, force: Bool = false) {
        guard force || id != selectedSourceID, let id, let source = sources.first(where: { $0.id == id }) else { return }
        if let current = selectedSourceID { savedPositions[current] = positions }
        selectedSourceID = id
        schema = parsed[id] ?? source.parse()
        original = schema
        selectedTable = nil
        editError = nil
        positions = savedPositions[id] ?? SchemaLayout.layout(schema, metrics: metrics)
        fillMissingPositions()
        fitRequest += 1
        status = .loaded
    }

    func autoLayout() {
        positions = SchemaLayout.layout(schema, metrics: metrics)
        fitRequest += 1
    }

    func fit() {
        fitRequest += 1
    }

    func move(_ table: String, to point: SchemaPoint) {
        positions[table] = SchemaPoint(x: max(0, point.x), y: max(0, point.y))
    }

    func discardEdits() {
        schema = original
        editError = nil
        if let selectedTable, schema.table(selectedTable) == nil { self.selectedTable = nil }
        fillMissingPositions()
    }

    private func fillMissingPositions() {
        let missing = schema.tables.filter { positions[$0.name] == nil }
        guard !missing.isEmpty else { return }
        let bounds = SchemaLayout.bounds(positions, schema: schema, metrics: metrics)
        var x = 0.0
        for table in missing {
            positions[table.name] = SchemaPoint(x: x, y: bounds.height + metrics.rowGap * 2)
            x += metrics.cardWidth + metrics.columnGap
        }
    }


    func edit(_ change: (inout DBSchema) throws -> Void) {
        var copy = schema
        do {
            try change(&copy)
            schema = copy
            editError = nil
            fillMissingPositions()
        } catch let error as SchemaEditError {
            editError = error.message
        } catch {
            editError = "\(error)"
        }
    }

    func addTable() {
        var added: String?
        edit { added = try $0.addTable() }
        guard let added else { return }
        let bounds = SchemaLayout.bounds(positions.filter { $0.key != added }, schema: schema, metrics: metrics)
        positions[added] = SchemaPoint(x: bounds.width + metrics.columnGap, y: 0)
        selectedTable = added
    }

    func renameTable(_ old: String, to new: String) {
        guard old != new else { return }
        let point = positions[old]
        edit { try $0.renameTable(old, to: new) }
        guard editError == nil else { return }
        if let point { positions[new] = point }
        if selectedTable == old { selectedTable = new }
    }

    func removeTable(_ name: String) {
        edit { $0.removeTable(name) }
        if selectedTable == name { selectedTable = nil }
    }


    func exportText(_ format: SchemaExportFormat) -> String {
        SchemaExport.render(schema, as: format)
    }

    func copy(_ format: SchemaExportFormat) {
        Pasteboard.copy(exportText(format))
    }

    func save(_ format: SchemaExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "schema.\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportText(format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            editError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

enum SchemaDemo {
    static let files: [SchemaFile] = [
        SchemaFile(path: "prisma/schema.prisma", text: """
        datasource db {
          provider = "postgresql"
          url      = env("DATABASE_URL")
        }

        model Workspace {
          id        Int       @id @default(autoincrement())
          name      String    @unique
          createdAt DateTime  @default(now())
          members   Member[]
          projects  Project[]
        }

        model Member {
          id          Int       @id @default(autoincrement())
          email       String    @unique
          role        Role      @default(DEVELOPER)
          workspace   Workspace @relation(fields: [workspaceId], references: [id], onDelete: Cascade)
          workspaceId Int
          tasks       Task[]
        }

        model Project {
          id          Int       @id @default(autoincrement())
          slug        String
          workspace   Workspace @relation(fields: [workspaceId], references: [id])
          workspaceId Int
          tasks       Task[]
          deployment  Deployment?
        }

        model Task {
          id         Int      @id @default(autoincrement())
          title      String
          done       Boolean  @default(false)
          project    Project  @relation(fields: [projectId], references: [id])
          projectId  Int
          assignee   Member?  @relation(fields: [assigneeId], references: [id])
          assigneeId Int?
        }

        model Deployment {
          id        Int      @id @default(autoincrement())
          url       String
          project   Project  @relation(fields: [projectId], references: [id])
          projectId Int      @unique
        }

        enum Role {
          OWNER
          DEVELOPER
          VIEWER
        }
        """),
    ]
}
