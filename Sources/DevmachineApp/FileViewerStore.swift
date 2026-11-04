import Foundation
import Combine
import DevmachineCore

/// Reads one file for the viewer, from whichever side the session runs on.
/// Reading only: nothing here writes a file. What a tab showed is kept
/// (`cached`, the last few), so coming back to its tab is as quick as
/// coming back to a session; Reload reads again.
@MainActor
final class FileViewerStore: ObservableObject {
    /// One file of one session: the same path on two hosts is two files.
    struct Key: Hashable {
        let target: CommandTarget
        let path: String
    }

    static let cacheCap = 8

    @Published private(set) var preview: FilePreview?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    /// Markdown starts rendered; the switch shows the source instead.
    @Published var showsSource = false
    /// The pane is on screen only while it holds a file.
    @Published private(set) var isOpen = false

    /// Told the path of every file shown, so the strip over the terminal
    /// can keep a tab for it.
    var onOpen: ((String) -> Void)?
    /// Told when the file leaves the screen, so the terminal it stood in
    /// for can be asked to draw again.
    var onClose: (() -> Void)?

    private let host: HostRunner
    private var current: (target: CommandTarget, path: String)?
    private var cached: [Key: FilePreview] = [:]
    private var shownAt: [Key: Date] = [:]

    init(host: HostRunner = HostRunner()) {
        self.host = host
    }

    var path: String? { current?.path }

    func open(_ target: CommandTarget, path: String) {
        current = (target, path)
        isOpen = true
        errorText = nil
        showsSource = false
        let key = Key(target: target, path: path)
        preview = cached[key]
        shownAt[key] = Date()
        onOpen?(path)
        if preview == nil { load() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        current = nil
        preview = nil
        errorText = nil
        onClose?()
    }

    /// Drops what was read of `path`, on any host: its tab is gone, and the
    /// next open reads it again.
    func forget(path: String) {
        for key in cached.keys where key.path == path {
            cached[key] = nil
            shownAt[key] = nil
        }
    }

    func reload() {
        guard current != nil else { return }
        load()
    }

    private func load() {
        guard let (target, path) = current else { return }
        isLoading = true
        let host = self.host
        let command = FilePreviewReader.command(path: path)
        Task.detached {
            let result = try? host.runCapturingAnywhere(target, command)
            let parsed = result.flatMap { FilePreviewReader.parse($0.stdout, path: path) }
            let message = parsed == nil ? Self.failure(result) : nil
            await MainActor.run {
                guard let cur = self.current, cur.target == target, cur.path == path else { return }
                self.isLoading = false
                self.preview = parsed
                self.errorText = message
                if let parsed { self.remember(parsed, for: Key(target: target, path: path)) }
            }
        }
    }

    private func remember(_ preview: FilePreview, for key: Key) {
        cached[key] = preview
        shownAt[key] = Date()
        for old in LRUEviction.keysToEvict(detachedAt: shownAt, cap: Self.cacheCap) {
            cached[old] = nil
            shownAt[old] = nil
        }
    }

    nonisolated private static func failure(
        _ result: (stdout: String, stderr: String, exitCode: Int32)?
    ) -> String {
        guard let result else { return "Could not read the file" }
        let line = result.stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? "Could not read the file"
    }
}
