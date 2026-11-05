import XCTest
import SwiftUI
import DevmachineCore
@testable import DevmachineApp

private final class SilentRunner: CommandRunner, @unchecked Sendable {
    func run(executable: String, args: [String], environment: [String: String]?) throws -> String { "" }
}

@MainActor
final class FilesTabTests: XCTestCase {
    private let root = "/home/alice/dev/dash"

    private func row(_ name: String, kind: FileTreeEntry.Kind, depth: Int = 0) -> FileTreeRow {
        FileTreeRow(path: root + "/" + name, name: name, depth: depth, kind: kind, isPlaceholder: false)
    }

    func testDirectoriesShowAnOpenFolderOnlyWhenExpanded() {
        let directory = row("Sources", kind: .directory)

        XCTAssertEqual(FileTreeIcon.name(for: directory, expanded: false), "folder")
        XCTAssertEqual(FileTreeIcon.name(for: directory, expanded: true), "folder.fill")
    }

    func testFileIconsFollowTheExtension() {
        let cases: [(String, String)] = [
            ("App.swift", "chevron.left.forwardslash.chevron.right"),
            ("deploy.sh", "chevron.left.forwardslash.chevron.right"),
            ("README.md", "doc.text"),
            ("notes.txt", "doc.text"),
            ("Package.resolved", "doc"),
            ("package.json", "curlybraces"),
            ("config.YML", "curlybraces"),
            ("Package.lock", "curlybraces"),
            ("wallpaper.jpg", "photo"),
            ("logo.SVG", "photo"),
            ("Makefile", "doc")
        ]

        for (name, expected) in cases {
            XCTAssertEqual(
                FileTreeIcon.name(for: row(name, kind: .file), expanded: false),
                expected,
                name
            )
        }
    }

    func testDotfilesAndBuildDirectoriesAreDimmed() {
        XCTAssertTrue(FileTreeIcon.isDimmed(".gitignore"))
        XCTAssertTrue(FileTreeIcon.isDimmed("node_modules"))
        XCTAssertTrue(FileTreeIcon.isDimmed(".build"))
        XCTAssertTrue(FileTreeIcon.isDimmed("vendor"))
        XCTAssertFalse(FileTreeIcon.isDimmed("Sources"))
    }

    func testTheHeaderShowsTheLastTwoPathComponents() {
        XCTAssertEqual(FilesTab.shortPath(root), "dev/dash")
        XCTAssertEqual(FilesTab.shortPath("/home"), "home")
        XCTAssertEqual(FilesTab.shortPath("/"), "/")
    }

    func testIndentationGrowsWithDepth() {
        XCTAssertEqual(FilesTab.indent(0), 0)
        XCTAssertEqual(FilesTab.indent(3), 42)
    }

    // The tab's onAppear starts the store, which would wipe seeded state — so
    // the fixture starts it first and lets that resolution land.
    private func seededStore() async throws -> FileTreeStore {
        let store = FileTreeStore(host: HostRunner(remote: RemoteService(runner: SilentRunner())))
        store.start(.remote(alias: "acme-devmachine", session: "dash"))
        let deadline = Date().addingTimeInterval(2)
        while store.isLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        store.root = root
        store.children = [
            root: [
                FileTreeEntry(name: "Sources", kind: .directory),
                FileTreeEntry(name: "Tests", kind: .directory),
                FileTreeEntry(name: ".gitignore", kind: .file),
                FileTreeEntry(name: "README.md", kind: .file)
            ],
            root + "/Sources": [FileTreeEntry(name: "App.swift", kind: .file)],
            root + "/Tests": []
        ]
        store.expanded = [root + "/Sources", root + "/Tests"]
        return store
    }

    private func render(_ store: FileTreeStore) throws -> NSImage {
        let view = FilesTab(store: store, target: .remote(alias: "acme-devmachine", session: "dash"))
            .environmentObject(AppModel(store: SessionStore(runner: SilentRunner())))
            .environmentObject(FileViewerStore(highlighter: PlainHighlighter()))
            .environmentObject(FileSearchStore())
            .environmentObject(FilesStore(service: FileService(host: HostRunner(remote: RemoteService(runner: SilentRunner()))), runner: SilentRunner()))
            .frame(width: 300, height: 420)
        return try XCTUnwrap(ImageRenderer(content: view).nsImage)
    }

    func testTheTabRendersTheTreeAndBothEmptyStates() async throws {
        let tree = try await seededStore()
        let withTree = try render(tree)
        XCTAssertEqual(withTree.size.width, 300)
        XCTAssertEqual(withTree.size.height, 420)
        XCTAssertEqual(
            tree.visibleRows.map(\.name),
            ["Sources", "App.swift", "Tests", "empty", ".gitignore", "README.md"]
        )

        let noPath = FileTreeStore(host: HostRunner(remote: RemoteService(runner: SilentRunner())))
        XCTAssertEqual(try render(noPath).size.width, 300)

        let failed = FileTreeStore(host: HostRunner(remote: RemoteService(runner: SilentRunner())))
        failed.errorText = "Could not reach the host"
        XCTAssertEqual(try render(failed).size.width, 300)
    }
}
