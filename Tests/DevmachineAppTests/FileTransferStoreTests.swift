import XCTest
import DevmachineCore
@testable import DevmachineApp

private final class CannedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []
    let result: (stdout: String, stderr: String, exitCode: Int32)

    init(_ stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        result = (stdout, stderr, exitCode)
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func run(executable: String, args: [String], environment: [String: String]?) throws -> String {
        try runCapturing(executable: executable, args: args, environment: environment).stdout
    }

    func runCapturing(executable: String, args: [String], environment: [String: String]?) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        lock.lock()
        stored.append(args)
        lock.unlock()
        return result
    }
}

/// What a download did to its card, and whether the result was already on
/// screen when the card went away.
@MainActor
private final class CardLog {
    enum Event: Equatable {
        case begin(String)
        case advance(done: Int64, total: Int64?)
        case end(noticeShown: Bool)
    }

    private(set) var events: [Event] = []
    weak var transfers: FileTransferStore?

    var cards: TransferCards {
        TransferCards(
            begin: { [self] label in
                events.append(.begin(label))
                return UUID()
            },
            advance: { [self] _, done, total in events.append(.advance(done: done, total: total)) },
            end: { [self] _ in events.append(.end(noticeShown: transfers?.notice != nil)) })
    }
}

@MainActor
final class FileTransferStoreTests: XCTestCase {
    private func store(
        _ runner: CannedRunner, downloads: URL = URL(fileURLWithPath: "/Users/alice/Downloads"),
        cards: CardLog? = nil
    ) -> FileTransferStore {
        let transfers = FileTransferStore(
            cli: { DevmachineCLI(executable: "/opt/homebrew/bin/devmachine", runner: runner) },
            downloadsDirectory: downloads,
            dragDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("dm-drag-tests"),
            home: "/Users/alice",
            cards: (cards ?? CardLog()).cards)
        cards?.transfers = transfers
        return transfers
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOneSavedFileSaysWhereAndOffersFinder() {
        let notice = FileTransferStore.notice(
            forDownloads: [DownloadedFile(
                remote: "/home/acme/a.png", local: "/Users/alice/Downloads/a.png", bytes: 3, folder: false, error: nil)],
            into: "/Users/alice/Downloads", home: "/Users/alice")
        XCTAssertEqual(notice.title, "Saved to ~/Downloads/a.png")
        XCTAssertEqual(notice.reveal, URL(fileURLWithPath: "/Users/alice/Downloads/a.png"))
        XCTAssertFalse(notice.failed)
    }

    func testAPartialDownloadNamesWhatFailed() {
        let notice = FileTransferStore.notice(
            forDownloads: [
                DownloadedFile(remote: "/a", local: "/Users/alice/Downloads/a", bytes: 1, folder: false, error: nil),
                DownloadedFile(remote: "/b", local: nil, bytes: 0, folder: false, error: "/b does not exist"),
            ],
            into: "/Users/alice/Downloads", home: "/Users/alice")
        XCTAssertEqual(notice.title, "Saved 1 of 2 to ~/Downloads")
        XCTAssertEqual(notice.detail, "/b does not exist")
        XCTAssertTrue(notice.failed)
    }

    func testAFailedDownloadHasNothingToReveal() {
        let notice = FileTransferStore.notice(
            forDownloads: [DownloadedFile(remote: "/b", local: nil, bytes: 0, folder: false, error: "/b cannot be read")],
            into: "/Users/alice/Downloads", home: "/Users/alice")
        XCTAssertEqual(notice.title, "Could not download b")
        XCTAssertNil(notice.reveal)
        XCTAssertTrue(notice.failed)
    }

    func testAnUploadSaysWhichFolderItLandedIn() {
        let notice = FileTransferStore.notice(
            forUploads: [UploadedFile(local: "/x.png", remote: "/home/acme/proj/x-20260930-143012.png", bytes: 1, error: nil)],
            into: "/home/acme/proj")
        XCTAssertEqual(notice.title, "Uploaded x-20260930-143012.png to proj")
    }

    func testDownloadCallsTheCLIIntoDownloadsAndShowsTheResult() async {
        let runner = CannedRunner(
            #"[{"remote":"/home/acme/a b.png","local":"/Users/alice/Downloads/a b.png","bytes":3,"folder":false}]"#)
        let transfers = store(runner)

        await transfers.download(["/home/acme/a b.png"], workspace: "acme")

        XCTAssertEqual(runner.calls.first, FileTransfer.downloadArguments(
            paths: ["/home/acme/a b.png"], workspace: "acme", to: "/Users/alice/Downloads", progress: true))
        XCTAssertEqual(transfers.notice?.title, "Saved to ~/Downloads/a b.png")
        XCTAssertTrue(transfers.busy.isEmpty)
    }

    func testADownloadShowsItsBytesOnACardThatGoesBeforeTheNotice() async {
        let progress = #"{"remote":"/home/acme/a.png","done":0,"total":8}"# + "\n"
            + #"{"remote":"/home/acme/b.png","done":0,"total":2}"# + "\n"
            + #"{"remote":"/home/acme/a.png","done":8,"total":8}"# + "\n"
        let runner = CannedRunner(
            #"[{"remote":"/home/acme/a.png","local":"/Users/alice/Downloads/a.png","bytes":8,"folder":false},"#
                + #"{"remote":"/home/acme/b.png","bytes":0,"folder":false,"error":"/home/acme/b.png cannot be read"}]"#,
            stderr: progress, exitCode: 1)
        let cards = CardLog()
        let transfers = store(runner, cards: cards)

        await transfers.download(["/home/acme/a.png", "/home/acme/b.png"], workspace: "acme")

        XCTAssertEqual(cards.events, [
            .begin("Downloading 2 items"),
            .advance(done: 0, total: 8), .advance(done: 0, total: 10), .advance(done: 8, total: 10),
            .end(noticeShown: false),
        ])
        XCTAssertEqual(transfers.notice?.title, "Saved 1 of 2 to ~/Downloads")
    }

    func testAFolderDownloadCountsBytesWithNoTotal() async {
        let progress = #"{"remote":"/home/acme/site","done":0,"total":0}"# + "\n"
            + #"{"remote":"/home/acme/site","done":4096,"total":0}"# + "\n"
        let runner = CannedRunner(
            #"[{"remote":"/home/acme/site","local":"/Users/alice/Downloads/site.tar.gz","bytes":4096,"folder":true}]"#,
            stderr: progress)
        let cards = CardLog()
        let transfers = store(runner, cards: cards)

        await transfers.download(["/home/acme/site"], workspace: "acme")

        XCTAssertEqual(cards.events, [
            .begin("Downloading site"), .advance(done: 0, total: nil), .advance(done: 4096, total: nil),
            .end(noticeShown: false),
        ])
    }

    func testAFailedDownloadClosesItsCardAndSaysWhy() async {
        let runner = CannedRunner("", stderr: "Error: no workspace named acme\n", exitCode: 1)
        let cards = CardLog()
        let transfers = store(runner, cards: cards)

        await transfers.download(["/home/acme/a.png"], workspace: "acme")

        XCTAssertEqual(cards.events, [.begin("Downloading a.png"), .end(noticeShown: false)])
        XCTAssertEqual(transfers.notice?.title, "Could not download a.png")
        XCTAssertEqual(transfers.notice?.detail, "Error: no workspace named acme")
    }

    func testAnOlderCLIIsToldToUpdate() async {
        let runner = CannedRunner("", stderr: "Error: unknown command \"download\" for \"devmachine\"\n", exitCode: 1)
        let transfers = store(runner)

        await transfers.download(["/home/acme/a.png"], workspace: "acme")

        XCTAssertEqual(transfers.notice?.title, "Could not download a.png")
        XCTAssertTrue(transfers.notice?.detail?.contains("devmachine update") ?? false)
    }

    func testADragExportsIntoAFolderOfItsOwnAndReturnsTheFile() async throws {
        let runner = CannedRunner(
            #"[{"remote":"/home/acme/site","local":"/tmp/x/site.tar.gz","bytes":9,"folder":true}]"#)
        let transfers = store(runner)

        let url = try await transfers.exportForDrag("/home/acme/site", workspace: "acme")

        XCTAssertEqual(url.path, "/tmp/x/site.tar.gz")
        let args = try XCTUnwrap(runner.calls.first)
        let to = try XCTUnwrap(args.firstIndex(of: "--to")).advanced(by: 1)
        XCTAssertTrue(args[to].contains("dm-drag-tests/"), args[to])
    }

    func testADragOfAMissingFileFailsTheDrop() async {
        let runner = CannedRunner(#"[{"remote":"/gone","bytes":0,"folder":false,"error":"/gone does not exist"}]"#)
        let transfers = store(runner)

        do {
            _ = try await transfers.exportForDrag("/gone", workspace: "acme")
            XCTFail("a missing file was handed to Finder")
        } catch {
            XCTAssertEqual(transfers.notice?.detail, "/gone does not exist")
        }
    }

    func testADroppedFolderIsRefusedBeforeTheCLIRuns() async throws {
        let runner = CannedRunner("[]")
        let transfers = store(runner)
        let dropped = try folder()

        let landed = await transfers.upload([dropped], into: "/home/acme/proj", workspace: "acme")

        XCTAssertEqual(landed, [])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(transfers.notice?.failed ?? false)
    }

    func testUploadSendsIntoTheFolderDroppedOn() async throws {
        let runner = CannedRunner(#"[{"local":"/x","remote":"/home/acme/proj/assets/x-20260930-143012.png","bytes":1}]"#)
        let transfers = store(runner)
        let file = try folder().appendingPathComponent("x.png")
        try Data("x".utf8).write(to: file)

        let landed = await transfers.upload([file], into: "/home/acme/proj/assets", workspace: "acme")

        XCTAssertEqual(landed, ["/home/acme/proj/assets/x-20260930-143012.png"])
        XCTAssertEqual(runner.calls.first, FileTransfer.uploadArguments(
            files: [file.path], workspace: "acme", directory: "/home/acme/proj/assets"))
    }

    func testAnUploadShowsACardUntilItsNoticeTakesOver() async throws {
        let runner = CannedRunner(#"[{"local":"/x","remote":"/home/acme/proj/x-20260930-143012.png","bytes":1}]"#)
        let cards = CardLog()
        let transfers = store(runner, cards: cards)
        let file = try folder().appendingPathComponent("x.png")
        try Data("x".utf8).write(to: file)

        _ = await transfers.upload([file], into: "/home/acme/proj", workspace: "acme")

        XCTAssertEqual(cards.events, [.begin("Uploading x.png"), .end(noticeShown: false)])
        XCTAssertEqual(transfers.notice?.title, "Uploaded x-20260930-143012.png to proj")
    }

    func testAFailedUploadClosesItsCardAndSaysWhy() async throws {
        let runner = CannedRunner("", stderr: "Error: no workspace named acme\n", exitCode: 1)
        let cards = CardLog()
        let transfers = store(runner, cards: cards)
        let file = try folder().appendingPathComponent("x.png")
        try Data("x".utf8).write(to: file)

        _ = await transfers.upload([file], into: "/home/acme/proj", workspace: "acme")

        XCTAssertEqual(cards.events, [.begin("Uploading x.png"), .end(noticeShown: false)])
        XCTAssertEqual(transfers.notice?.title, "Could not upload x.png")
    }

    func testARefusedUploadShowsNoCard() async throws {
        let cards = CardLog()
        let transfers = store(CannedRunner("[]"), cards: cards)

        _ = await transfers.upload([try folder()], into: "/home/acme/proj", workspace: "acme")

        XCTAssertEqual(cards.events, [])
    }

    func testALocalDropCopiesWithoutOverwriting() async throws {
        let source = try folder().appendingPathComponent("relatório final.txt")
        try Data("new".utf8).write(to: source)
        let destination = try folder()
        try Data("old".utf8).write(to: destination.appendingPathComponent("relatório final.txt"))
        let transfers = store(CannedRunner(""))

        let landed = await transfers.copyLocally([source], into: destination.path)

        XCTAssertEqual(landed, [destination.appendingPathComponent("relatório final-2.txt").path])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("relatório final.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: landed[0]), encoding: .utf8), "new")
    }

    func testDropsFromTheTreeItselfAreNotUploads() {
        let own = FileTreeDrag.localProvider(for: "/tmp")
        XCTAssertFalse(FileTreeDrag.acceptsDrop([own]))
        let finder = NSItemProvider(contentsOf: URL(fileURLWithPath: "/tmp")) ?? NSItemProvider()
        XCTAssertTrue(FileTreeDrag.acceptsDrop([finder]))
        XCTAssertFalse(FileTreeDrag.acceptsDrop([]))
    }

    func testARemoteDragPromisesTheFileNameAndType() {
        let row = FileTreeRow(path: "/home/acme/site", name: "site", depth: 0, kind: .directory, isPlaceholder: false)
        let provider = FileTreeDrag.remoteProvider(for: row) { _ in URL(fileURLWithPath: "/tmp/site.tar.gz") }
        XCTAssertEqual(provider.suggestedName, "site.tar.gz")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("org.gnu.gnu-zip-archive"))
        XCTAssertEqual(FileTreeDrag.contentType(forName: "a.png"), .png)
        XCTAssertEqual(FileTreeDrag.contentType(forName: "Makefile"), .data)
    }
}
