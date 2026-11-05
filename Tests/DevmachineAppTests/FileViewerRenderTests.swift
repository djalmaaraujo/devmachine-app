import XCTest
import SwiftUI
import DevmachineCore
@testable import DevmachineApp

private final class SampleRunner: CommandRunner, @unchecked Sendable {
    let stdout: String
    init(stdout: String) { self.stdout = stdout }
    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        stdout
    }
    func runCapturing(executable: String, args: [String], environment: [String: String]?) throws
        -> (stdout: String, stderr: String, exitCode: Int32) { (stdout, "", 0) }
}

@MainActor
final class FileViewerRenderTests: XCTestCase {
    /// Renders the pane so a broken view is caught here rather than in the app.
    /// Only the header is proof: `ScrollView` draws nothing under
    /// `ImageRenderer`, so the file's own text cannot be checked this way.
    /// `DEVMACHINE_RENDER=1` writes the image to /tmp for a look.
    func testTheCodePaneRenders() async throws {
        let code = """
        import Foundation

        struct Greeter {
            let name: String

            func greet() -> String {
                "Hello, \\(name)"
            }
        }
        """
        let data = Data(code.utf8)
        let payload = "\(data.count)\u{1e}" + data.base64EncodedString()
        let store = FileViewerStore(
            host: HostRunner(remote: RemoteService(runner: SampleRunner(stdout: payload))), highlighter: PlainHighlighter())
        store.open(.remote(alias: "acme-devmachine", session: "dash"), path: "/repo/notes.txt")

        let deadline = Date().addingTimeInterval(3)
        while store.preview == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.preview?.kind, .text)

        let view = FileViewerView()
            .environmentObject(store)
            .environmentObject(AppModel(store: SessionStore(runner: SampleRunner(stdout: ""))))
            .frame(width: 620, height: 420)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.width, 0)

        if ProcessInfo.processInfo.environment["DEVMACHINE_RENDER"] != nil,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/devmachine-viewer.png"))
        }
    }
}
