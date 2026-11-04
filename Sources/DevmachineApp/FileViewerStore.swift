import Foundation
import Combine
import HighlightSwift
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

    /// A file read and cut up, with its highlighted copy once there is one.
    struct Shown {
        var preview: FilePreview
        var layout: FileLayout
        var highlighted: [Int: AttributedString]?
    }

    @Published private(set) var preview: FilePreview?
    /// The file in pieces, set together with `preview`.
    @Published private(set) var layout: FileLayout?
    /// The highlighted copy of each piece, by its first line, once the
    /// highlighter has answered; plain text shows until then. Nil above
    /// `FilePreviewReader.highlightLimit`, and for markdown until its
    /// source is asked for.
    @Published private(set) var highlighted: [Int: AttributedString]?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    /// Markdown starts rendered; the switch shows the source instead.
    @Published var showsSource = false {
        didSet { if showsSource { highlightIfNeeded() } }
    }
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
    private var cached: [Key: Shown] = [:]
    private var shownAt: [Key: Date] = [:]
    /// One highlighter for the viewer: highlight.js in its own JavaScript
    /// context, asked once per file, never per piece.
    private static let highlighter = Highlight()

    init(host: HostRunner = HostRunner()) {
        self.host = host
    }

    var path: String? { current?.path }

    func open(_ target: CommandTarget, path: String) {
        current = (target, path)
        isOpen = true
        // A read still running for another file answers to nothing now.
        isLoading = false
        errorText = nil
        showsSource = false
        let key = Key(target: target, path: path)
        show(cached[key])
        shownAt[key] = Date()
        onOpen?(path)
        if preview == nil { load() } else { highlightIfNeeded() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        current = nil
        isLoading = false
        show(nil)
        errorText = nil
        onClose?()
    }

    private func show(_ shown: Shown?) {
        preview = shown?.preview
        layout = shown?.layout
        highlighted = shown?.highlighted
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
            // Cut up here, off the main thread, where a 2 MB file costs nothing on screen.
            let shown = parsed.map { Shown(preview: $0, layout: FileLayout(text: $0.text ?? "", kind: $0.kind)) }
            let message = parsed == nil ? Self.failure(result) : nil
            await MainActor.run {
                guard let cur = self.current, cur.target == target, cur.path == path else { return }
                self.isLoading = false
                self.show(shown)
                self.errorText = message
                if let shown {
                    self.remember(shown, for: Key(target: target, path: path))
                    self.highlightIfNeeded()
                }
            }
        }
    }

    private func remember(_ shown: Shown, for key: Key) {
        cached[key] = shown
        shownAt[key] = Date()
        for old in LRUEviction.keysToEvict(detachedAt: shownAt, cap: Self.cacheCap) {
            cached[old] = nil
            shownAt[old] = nil
        }
    }

    /// The highlight.js name for what is on screen, when highlighting is
    /// worth it: code under the limit, and markdown's source once asked for.
    static func highlightLanguage(kind: FilePreviewKind, byteCount: Int, showsSource: Bool) -> String? {
        guard byteCount <= FilePreviewReader.highlightLimit else { return nil }
        switch kind {
        case let .code(language): return language
        case .markdown: return showsSource ? "markdown" : nil
        default: return nil
        }
    }

    /// Highlights the whole file once, off the main thread, and cuts the
    /// result into the same pieces as the lines; a result that does not
    /// line up with them is dropped and the plain text stays.
    private func highlightIfNeeded() {
        guard highlighted == nil, let (target, path) = current, let preview, let layout,
              let text = preview.text,
              let language = Self.highlightLanguage(kind: preview.kind, byteCount: text.utf8.count, showsSource: showsSource)
        else { return }
        let key = Key(target: target, path: path)
        Task {
            guard let attributed = try? await Self.highlighter.attributedText(text, language: language, colors: .dark(.atomOne)),
                  let pieces = AttributedLines.split(attributed, into: layout.lines)
            else { return }
            if var shown = cached[key] {
                shown.highlighted = pieces
                cached[key] = shown
            }
            guard let cur = current, cur.target == target, cur.path == path else { return }
            highlighted = pieces
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
