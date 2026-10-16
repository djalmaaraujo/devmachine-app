import AppKit
import DevmachineCore

/// What a finished transfer says, with the file to show in Finder when there
/// is one. A failure stays until it is closed; a success goes by itself.
struct TransferNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String?
    let reveal: URL?
    let failed: Bool

    static func == (lhs: TransferNotice, rhs: TransferNotice) -> Bool {
        lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.reveal == rhs.reveal
            && lhs.failed == rhs.failed
    }
}

/// The job card a download shows while its bytes arrive, the same card the
/// workspace sweep uses.
struct TransferCards: Sendable {
    let begin: @MainActor @Sendable (String) -> UUID?
    let advance: @MainActor @Sendable (UUID, Int64, Int64?) -> Void
    let end: @MainActor @Sendable (UUID) -> Void

    /// The result's notice takes the card's place, so the card goes at once
    /// instead of lingering on a checkmark beside it.
    static let app = TransferCards(
        begin: { AppModel.shared?.beginTransfer(label: $0, total: 0) },
        advance: { AppModel.shared?.advanceDownload($0, done: $1, total: $2) },
        end: { AppModel.shared?.dropTask($0) })
}

/// Moves files between the Files tab and this Mac through the CLI, and keeps
/// what the tab shows while that runs: which rows are busy, and the result.
@MainActor
final class FileTransferStore: ObservableObject {
    static let shared = FileTransferStore()

    @Published var busy: Set<String> = []
    @Published var notice: TransferNotice?

    private let cli: @Sendable () throws -> DevmachineCLI
    private let downloadsDirectory: URL
    private let dragDirectory: URL
    private let home: String
    private let cards: TransferCards

    init(
        cli: @escaping @Sendable () throws -> DevmachineCLI = { try DevmachineCLI.resolve() },
        downloadsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads"),
        dragDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devmachine-drag"),
        home: String = NSHomeDirectory(),
        cards: TransferCards = .app
    ) {
        self.cli = cli
        self.downloadsDirectory = downloadsDirectory
        self.dragDirectory = dragDirectory
        self.home = home
        self.cards = cards
    }

    func download(_ paths: [String], workspace: String) async {
        guard !paths.isEmpty else { return }
        busy.formUnion(paths)
        defer { busy.subtract(paths) }
        let directory = downloadsDirectory.path
        do {
            let files = try await fetch(paths, workspace: workspace, into: directory)
            show(Self.notice(forDownloads: files, into: directory, home: home))
        } catch {
            show(Self.failure("Could not download \(Self.names(paths))", error))
        }
    }

    /// Runs the CLI with a card that follows its bytes. Every count is drawn
    /// before the card goes, so a late one never lands on a closed card.
    private func fetch(_ paths: [String], workspace: String, into directory: String) async throws
        -> [DownloadedFile] {
        let card = cards.begin("Downloading \(Self.names(paths))")
        let (counts, feed) = AsyncStream.makeStream(of: DownloadProgress.self)
        let cards = self.cards
        let drawn = Task { @MainActor in
            var tally = DownloadTally()
            for await count in counts {
                tally.record(count)
                if let card { cards.advance(card, tally.done, tally.total) }
            }
        }
        let cli = self.cli
        let outcome = await Task.detached { () -> Result<[DownloadedFile], Error> in
            defer { feed.finish() }
            return Result {
                try cli().download(paths: paths, workspace: workspace, to: directory) { feed.yield($0) }
            }
        }.value
        await drawn.value
        if let card { cards.end(card) }
        return try outcome.get()
    }

    /// What a drop in Finder asks for: the file, saved where the system can
    /// take it from. Each drag gets a folder of its own, so two drags of the
    /// same name never meet.
    func exportForDrag(_ path: String, workspace: String) async throws -> URL {
        busy.insert(path)
        defer { busy.remove(path) }
        let directory = dragDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let files = try await fetch([path], workspace: workspace, into: directory.path)
            guard let file = files.first else {
                throw DevmachineCLIError.commandFailed("The CLI gave no result for the download.")
            }
            if let error = file.error { throw DevmachineCLIError.commandFailed(error) }
            guard let local = file.local else {
                throw DevmachineCLIError.commandFailed("The CLI gave no path for \(path).")
            }
            return URL(fileURLWithPath: local)
        } catch {
            show(Self.failure("Could not download \(Self.names([path]))", error))
            throw error
        }
    }

    /// Returns where the files landed, so the tree can point at them.
    func upload(_ files: [URL], into folder: String, workspace: String) async -> [String] {
        if let refusal = Self.refusal(for: files) {
            show(refusal)
            return []
        }
        let cli = self.cli
        let paths = files.map(\.path)
        // The card a drop on a pane shows, so a drop on the tree is seen
        // while it runs and not only once the notice says it is done. The CLI
        // reports no bytes for an upload, so the bar stays empty until then.
        // It goes before the notice, which takes its place.
        let card = cards.begin("Uploading \(Self.names(paths))")
        busy.insert(folder)
        defer { busy.remove(folder) }
        let outcome = await Task.detached {
            Result { try cli().upload(files: paths, workspace: workspace, directory: folder) }
        }.value
        if let card { cards.end(card) }
        do {
            let uploaded = try outcome.get()
            show(Self.notice(forUploads: uploaded, into: folder))
            return uploaded.compactMap(\.remote)
        } catch {
            show(Self.failure("Could not upload \(Self.names(paths))", error))
            return []
        }
    }

    /// Both sides are this Mac: a copy, never over a file already there.
    func copyLocally(_ files: [URL], into folder: String) async -> [String] {
        busy.insert(folder)
        defer { busy.remove(folder) }
        let destination = URL(fileURLWithPath: folder)
        let copied = await Task.detached { () -> Result<[String], Error> in
            do {
                return .success(try files.map { source in
                    let name = FileTransfer.freeName(source.lastPathComponent) {
                        FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path)
                    }
                    let target = destination.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: source, to: target)
                    return target.path
                })
            } catch {
                return .failure(error)
            }
        }.value
        switch copied {
        case let .success(paths):
            show(TransferNotice(
                title: "Copied \(Self.names(files.map(\.path))) to \(FileTransfer.displayPath(folder, home: home))",
                detail: nil, reveal: paths.first.map { URL(fileURLWithPath: $0) }, failed: false))
            return paths
        case let .failure(error):
            show(Self.failure("Could not copy \(Self.names(files.map(\.path)))", error))
            return []
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func dismiss() {
        notice = nil
    }

    func show(_ notice: TransferNotice) {
        self.notice = notice
        guard !notice.failed else { return }
        let id = notice.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.notice?.id == id else { return }
            self.notice = nil
        }
    }

    static func notice(forDownloads files: [DownloadedFile], into directory: String, home: String) -> TransferNotice {
        let saved = files.filter { $0.error == nil && $0.local != nil }
        let failures = files.compactMap(\.error)
        let reveal = saved.first?.local.map { URL(fileURLWithPath: $0) }
        let detail = failures.isEmpty ? nil : failures.joined(separator: "\n")
        switch (saved.count, failures.count) {
        case (0, _):
            return TransferNotice(
                title: "Could not download \(names(files.map(\.remote)))", detail: detail, reveal: nil, failed: true)
        case (1, 0):
            return TransferNotice(
                title: "Saved to \(FileTransfer.displayPath(saved[0].local ?? "", home: home))",
                detail: nil, reveal: reveal, failed: false)
        case (_, 0):
            return TransferNotice(
                title: "Saved \(saved.count) items to \(FileTransfer.displayPath(directory, home: home))",
                detail: nil, reveal: reveal, failed: false)
        default:
            return TransferNotice(
                title: "Saved \(saved.count) of \(files.count) to \(FileTransfer.displayPath(directory, home: home))",
                detail: detail, reveal: reveal, failed: true)
        }
    }

    static func notice(forUploads files: [UploadedFile], into folder: String) -> TransferNotice {
        let sent = files.compactMap(\.remote)
        let failures = files.compactMap(\.error)
        let detail = failures.isEmpty ? nil : failures.joined(separator: "\n")
        let place = (folder as NSString).lastPathComponent
        if sent.isEmpty {
            return TransferNotice(
                title: "Could not upload \(names(files.map(\.local)))", detail: detail, reveal: nil, failed: true)
        }
        let what = sent.count == 1 ? (sent[0] as NSString).lastPathComponent : "\(sent.count) files"
        if failures.isEmpty {
            return TransferNotice(title: "Uploaded \(what) to \(place)", detail: nil, reveal: nil, failed: false)
        }
        return TransferNotice(
            title: "Uploaded \(sent.count) of \(files.count) to \(place)", detail: detail, reveal: nil, failed: true)
    }

    /// `upload` sends files; a folder in the drop stops it before anything
    /// is sent, so the folder is not half there.
    static func refusal(for files: [URL]) -> TransferNotice? {
        let folders = files.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !folders.isEmpty else { return nil }
        let refusal = UploadRefusal.folders(folders.map(\.lastPathComponent))
        return TransferNotice(title: refusal.title, detail: refusal.details, reveal: nil, failed: true)
    }

    static func failure(_ title: String, _ error: Error) -> TransferNotice {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return TransferNotice(title: title, detail: detail, reveal: nil, failed: true)
    }

    static func names(_ paths: [String]) -> String {
        guard paths.count == 1 else { return "\(paths.count) items" }
        return (paths[0] as NSString).lastPathComponent
    }
}
