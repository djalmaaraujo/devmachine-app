import SwiftUI
import AppKit
import HighlightSwift
import MarkdownUI
import DevmachineCore

/// Reads a file. It never writes one: there is no editing here on purpose, so
/// a file opened from a running session cannot be changed by accident.
struct FileViewerView: View {
    @EnvironmentObject var store: FileViewerStore
    @EnvironmentObject var model: AppModel
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
        case let .code(language):
            scroll { code(preview.text ?? "", language: language) }
        case .markdown:
            if store.showsSource {
                scroll { code(preview.text ?? "", language: "markdown") }
            } else {
                ScrollView(.vertical) {
                    Markdown(preview.text ?? "")
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top)
            }
        case .text:
            scroll {
                numbered(preview.text ?? "") {
                    Text(preview.text ?? "")
                        .font(.dm(12, design: .monospaced))
                        .foregroundStyle(Color.dmRowText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        case .image:
            imageBody(preview)
        case .binary:
            message("Binary file — nothing to show")
        case let .tooLarge(bytes):
            message("Too large to open here (\(Self.size(bytes)))")
        }
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

    /// Numbers in their own column, beside the text rather than inside it, so
    /// what you select and copy is the code alone.
    private func numbered<Content: View>(
        _ text: String, @ViewBuilder content: () -> Content
    ) -> some View {
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let count = body.split(separator: "\n", omittingEmptySubsequences: false).count
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...max(count, 1), id: \.self) { number in
                    Text(verbatim: "\(number)")
                        .font(.dm(12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.28))
                }
            }
            .fixedSize()
            .padding(.trailing, 10)
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1)
                .padding(.trailing, 12)
            content()
        }
    }

    private func code(_ text: String, language: String?) -> some View {
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return numbered(body) {
            CodeText(body)
                .highlightLanguage(language.flatMap(HighlightLanguage.init(rawValue:)) ?? .plaintext)
                .codeTextColors(.theme(.atomOne))
                .font(.dm(12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The file starts at the top left corner and fills the pane, the way an
    /// editor shows one. A plain scroll view centres content smaller than its
    /// viewport, which made a ten-line file float in the middle of the pane.
    private func scroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let body = content()
        return GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                body
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(
                        minWidth: proxy.size.width,
                        minHeight: proxy.size.height,
                        alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
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
