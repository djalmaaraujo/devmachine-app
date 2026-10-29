import XCTest
import SwiftUI
import DevmachineCore
@testable import DevmachineApp

@MainActor
final class SchemaPageRenderTests: XCTestCase {
    private let target = CommandTarget.remote(alias: "acme", session: "dash")

    func testDemoSchemaLoadsAndLaysOutEveryTable() {
        let store = SchemaStore(demo: true)
        store.load(target)
        XCTAssertEqual(store.status, .loaded)
        XCTAssertEqual(store.schema.tables.map(\.name), ["Workspace", "Member", "Project", "Task", "Deployment"])
        XCTAssertEqual(Set(store.positions.keys), Set(store.schema.tables.map(\.name)))
        XCTAssertFalse(store.isEdited)
    }

    func testModelingMarksTheSchemaEditedAndDiscardRestoresIt() {
        let store = SchemaStore(demo: true)
        store.load(target)
        store.addTable()
        XCTAssertTrue(store.isEdited)
        XCTAssertEqual(store.selectedTable, "new_table")
        XCTAssertNotNil(store.positions["new_table"])
        store.renameTable("new_table", to: "Member")
        XCTAssertEqual(store.editError, SchemaEditError.duplicateTable("Member").message)
        store.discardEdits()
        XCTAssertFalse(store.isEdited)
        XCTAssertNil(store.selectedTable)
        XCTAssertTrue(store.exportText(.prisma).contains("model Deployment {"))
    }

    func testRenamingATableKeepsItsPlaceAndDiscardPutsItBack() {
        let store = SchemaStore(demo: true)
        store.load(target)
        let place = store.positions["Project"]
        store.renameTable("Project", to: "Repository")
        XCTAssertNil(store.editError)
        XCTAssertEqual(store.positions["Repository"], place)
        store.discardEdits()
        XCTAssertEqual(store.positions["Project"], place)
    }

    func testThePageRenders() throws {
        let store = SchemaStore(demo: true)
        store.load(target)
        store.selectedTable = "Project"
        try snapshotPNG(
            SchemaPage(target: target, store: store)
                .frame(width: 1400, height: 820)
                .environment(\.colorScheme, .dark),
            name: "devmachine-schema")
    }

    private func snapshotPNG(_ view: some View, name: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.contentView = nil }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        if ProcessInfo.processInfo.environment["DEVMACHINE_RENDER"] != nil {
            try png.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
    }
}
