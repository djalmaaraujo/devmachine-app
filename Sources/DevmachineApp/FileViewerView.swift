import SwiftUI
import AppKit
import MarkdownUI
import DevmachineCore

/// Reads a file. It never writes one: there is no editing here on purpose, so
/// a file opened from a running session cannot be changed by accident.
struct FileViewerView: View {
    @EnvironmentObject var store: FileViewerStore
    /// Off under the strip over the terminal, which already holds the
    /// file's tab; on, the header carries the tab, with its × to close.
    var showsTab = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.dmSidebarBg)
        .environment(\.colorScheme, .dark)
    }

    /// A tab with the file's name, the way an editor labels what is open, and
    /// the path under it so two files with one name stay apart.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTab {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.dm(10))
                        .foregroundStyle(Color(hex: 0x5AA9E6))
                    Text(store.preview?.name
                        ?? (store.path as NSString?)?.lastPathComponent ?? "Viewer")
                        .font(.dm(11.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    DMIconButton(
                        systemImage: "xmark", size: 9, weight: .semibold,
                        tint: .white.opacity(0.45)
                    ) { store.close() }
                    .help("Close the file")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.dmContentBg)
                Spacer(minLength: 0)
            }
            .background(Color.dmSidebarBg)
            }

            HStack(spacing: 8) {
                Text(store.path ?? "")
                    .font(.dm(10))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if store.preview?.kind == .markdown {
                    Toggle(isOn: $store.showsSource) {
                        Text(verbatim: "Source").font(.dm(10))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .foregroundStyle(.white.opacity(0.6))
                }
                if let preview = store.preview {
                    Text(Self.size(preview.byteCount))
                        .font(.dm(10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                DMIconButton(
                    systemImage: "arrow.clockwise", size: 10, weight: .semibold,
                    tint: .white.opacity(0.5)
                ) { store.reload() }
                .help("Read the file again")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.dmContentBg)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.errorText {
            message(error)
        } else if let preview = store.preview {
            body(of: preview)
        } else if store.isLoading {
            message("Reading…")
        } else {
            message("No file")
        }
    }

    @ViewBuilder
    private func body(of preview: FilePreview) -> some View {
        switch preview.kind {
        case .code, .text:
            lines
        case .markdown:
            if store.showsSource {
                lines
            } else {
                markdown
            }
        case .image:
            imageBody(preview)
        case .binary:
            message("Binary file — nothing to show")
        case let .tooLarge(bytes):
            message("Too large to open here (\(Self.size(bytes)))")
        }
    }

    /// The document in pieces (`FileChunks.markdown`), each laid out as it
    /// comes on screen. One `Markdown` view of the whole file laid out
    /// thousands of blocks before the first frame: seconds for 200 KB.
    private var markdown: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array((store.layout?.markdown ?? []).enumerated()), id: \.offset) { piece in
                    Markdown(piece.element)
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .defaultScrollAnchor(.top)
    }

    /// The lines in pieces (`FileChunks.lines`), each one `Text` with its
    /// numbers in one `Text` beside it, laid out as they come on screen. A
    /// single `Text` of the whole file grows worse than its length (4.5 s at
    /// 130 KB). The width is the longest line's from the start, so the
    /// horizontal extent does not jump as pieces are laid out. Numbers in
    /// their own column, beside the text rather than inside it, so what you
    /// select and copy is the code alone.
    private var lines: some View {
        let layout = store.layout ?? FileLayout(text: "", kind: .text)
        let digits = String(layout.lines.last?.lastLine ?? 1).count
        let character = Self.characterWidth
        let numbers = character * CGFloat(digits)
        let text = character * CGFloat(layout.longestLine)
        return GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(layout.lines) { chunk in
                        HStack(alignment: .top, spacing: 0) {
                            Text(verbatim: chunk.lines.indices.map { String(chunk.firstLine + $0) }.joined(separator: "\n"))
                                .font(.dm(12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.28))
                                .multilineTextAlignment(.trailing)
                                .frame(width: numbers, alignment: .trailing)
                                .padding(.trailing, 10)
                            Rectangle()
                                .fill(Color.white.opacity(0.07))
                                .frame(width: 1)
                                .padding(.trailing, 12)
                            self.text(for: chunk)
                                .font(.dm(12, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(
                    minWidth: max(proxy.size.width, numbers + 23 + text + 28),
                    minHeight: proxy.size.height,
                    alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
        }
    }

    @ViewBuilder
    private func text(for chunk: LineChunk) -> some View {
        if let highlighted = store.highlighted?[chunk.id] {
            Text(highlighted)
        } else {
            Text(verbatim: chunk.text)
                .foregroundStyle(Color.dmRowText)
        }
    }

    /// One character of the viewer's monospaced font, at the current scale.
    static var characterWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: DMFont.size(12), weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    @ViewBuilder
    private func imageBody(_ preview: FilePreview) -> some View {
        if let data = preview.data, let image = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(16)
            }
        } else {
            message("This image could not be read")
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.dm(12))
                .foregroundStyle(Color.dmMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var icon: String { Self.icon(for: store.preview?.kind) }

    static func icon(for kind: FilePreviewKind?) -> String {
        switch kind {
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        case .binary: return "shippingbox"
        case .tooLarge: return "exclamationmark.triangle"
        default: return "doc.text"
        }
    }

    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
