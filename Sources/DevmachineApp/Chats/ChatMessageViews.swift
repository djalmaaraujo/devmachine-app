import SwiftUI
import AppKit
import MarkdownUI
import HighlightSwift
import DevmachineCore

struct ChatUserBubble: View {
    let text: String
    var fontSize: CGFloat = 13.5
    var leadingSpace: CGFloat = 120
    @Environment(\.dmMetrics) private var m

    var body: some View {
        HStack {
            Spacer(minLength: m.pt(leadingSpace))
            Text(verbatim: text)
                .font(.dm(fontSize))
                .foregroundStyle(Color.white.opacity(0.95))
                .textSelection(.enabled)
                .padding(.horizontal, m.pt(fontSize > 12.5 ? 14 : 10))
                .padding(.vertical, m.pt(fontSize > 12.5 ? 10 : 6))
                .dmSurface(Color.white.opacity(0.08), radius: fontSize > 12.5 ? DMRadius.card : DMRadius.toast,
                           style: .continuous)
        }
    }
}

struct ChatToolLine: View {
    let tool: ChatTool
    @Environment(\.dmMetrics) private var m

    private var symbol: String {
        switch tool.name.lowercased() {
        case "read", "view": return "doc.text"
        case "grep", "glob", "search", "websearch": return "magnifyingglass"
        case "bash", "command", "shell", "exec": return "terminal"
        case "webfetch", "fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    var body: some View {
        HStack(spacing: m.pt(7)) {
            Image(systemName: symbol).font(.dm(10.5))
            Text(verbatim: tool.line).font(.dm(11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.right").font(.dm(8, weight: .semibold))
        }
        .foregroundStyle(Color.dmMuted)
        .padding(.horizontal, m.pt(9))
        .padding(.vertical, m.pt(5))
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: m.pt(DMRadius.row)))
        .dmHelp(tool.line)
    }
}

/// A tool the harness refused: chats run one message at a time, so
/// nobody is there to approve it.
struct ChatDeniedLine: View {
    let tool: ChatTool
    @Environment(\.dmMetrics) private var m

    static func text(_ tool: ChatTool) -> String {
        "Blocked: \(tool.name.isEmpty ? "a tool" : tool.name) needs approval"
    }

    var body: some View {
        HStack(spacing: m.pt(7)) {
            Image(systemName: "lock.fill").font(.dm(10))
            Text(verbatim: Self.text(tool)).font(.dm(11.5, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(Color.orange.opacity(0.85))
        .padding(.horizontal, m.pt(9))
        .padding(.vertical, m.pt(5))
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: m.pt(DMRadius.row)))
        .dmHelp(tool.summary.isEmpty ? Self.text(tool) : "\(tool.name) \(tool.summary)")
    }
}

/// An answer: its tool lines, then the text as markdown. While it streams
/// a cursor follows the last word.
struct ChatAnswerView: View {
    let message: ChatMessage
    var streaming = false
    var fontSize: CGFloat = 13.5
    /// What the CLI is doing before the answer starts, beside the cursor.
    var status: String?
    @Environment(\.dmMetrics) private var m

    static let cursorURL = "chat-cursor:end"

    var body: some View {
        VStack(alignment: .leading, spacing: m.pt(12)) {
            if !message.tools.isEmpty || !message.denied.isEmpty {
                VStack(alignment: .leading, spacing: m.pt(8)) {
                    ForEach(Array(message.tools.enumerated()), id: \.offset) { _, tool in
                        ChatToolLine(tool: tool)
                    }
                    ForEach(Array(message.denied.enumerated()), id: \.offset) { _, tool in
                        ChatDeniedLine(tool: tool)
                    }
                }
            }
            if streaming, !DemoMode.isActive {
                TimelineView(.periodic(from: .now, by: Self.blink)) { context in
                    answer(cursor: ChatCursor.isOn(at: context.date, period: Self.blink))
                }
            } else if !message.text.isEmpty || streaming {
                answer(cursor: streaming ? true : nil)
            }
        }
        .onAppear { announce(shownStatus) }
        .onChange(of: shownStatus) { _, status in announce(status) }
    }

    private var shownStatus: String? { streaming ? status : nil }

    @ViewBuilder
    private func answer(cursor: Bool?) -> some View {
        if let status = shownStatus, message.text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: m.pt(6)) {
                Text(verbatim: cursor == true ? "▍" : "\u{2007}")
                    .font(.dm(fontSize))
                    .foregroundStyle(ChatMarkdown.link)
                    .accessibilityHidden(true)
                statusText(status)
            }
        } else {
            text(cursor: cursor)
            if let status = shownStatus { statusText(status) }
        }
    }

    private func statusText(_ status: String) -> some View {
        Text(verbatim: status)
            .font(.dm(fontSize - 2))
            .foregroundStyle(Color.dmMuted)
            .demoClickTarget("chat:status")
    }

    /// Each new status is read out once, behind anything more urgent; the
    /// answer's own tokens are not.
    private func announce(_ status: String?) {
        guard let status, !DemoMode.isActive else { return }
        var announcement = AttributedString(status)
        announcement.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    static let blink: TimeInterval = 0.55

    private func text(cursor: Bool?) -> some View {
        Markdown(ChatCursor.markdown(message.text, cursor: cursor, url: Self.cursorURL))
            .markdownTheme(ChatMarkdown.theme(fontSize: fontSize))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                url.absoluteString == Self.cursorURL ? .handled : .systemAction
            })
    }
}

/// The bar after the last word while an answer is coming. It blinks; off,
/// a figure space of about its width keeps the line from moving.
enum ChatCursor {
    static func isOn(at date: Date, period: TimeInterval) -> Bool {
        Int(date.timeIntervalSinceReferenceDate / period) % 2 == 0
    }

    /// `cursor` nil: no cursor at all (the answer ended).
    static func markdown(_ text: String, cursor: Bool?, url: String) -> String {
        guard let cursor else { return text }
        let glyph = cursor ? "▍" : "\u{2007}"
        return text + " [\(glyph)](\(url))"
    }
}

@MainActor
enum ChatMarkdown {
    static let inlineCode = Color(hex: 0xE6B673)
    static let link = Color(hex: 0x5AA9E6)

    static func theme(fontSize: CGFloat) -> Theme {
        Theme.basic
            .text {
                ForegroundColor(Color.white.opacity(0.88))
                FontSize(DMFont.size(fontSize))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.93))
                ForegroundColor(inlineCode)
            }
            .link {
                ForegroundColor(link)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(Color.white)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: .zero, bottom: .em(0.8))
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: .em(0.25))
            }
            .codeBlock { configuration in
                ChatCodeBlock(language: configuration.language ?? "", code: configuration.content)
                    .markdownMargin(top: .zero, bottom: .em(0.8))
            }
    }
}

struct ChatCodeBlock: View {
    let language: String
    let code: String
    @Environment(\.dmMetrics) private var m
    @State private var copied = false

    private var trimmedCode: String { code.hasSuffix("\n") ? String(code.dropLast()) : code }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language.isEmpty ? "text" : language)
                    .font(.dm(10.5, design: .monospaced)).foregroundStyle(Color.dmMuted)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmedCode, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    HStack(spacing: m.pt(4)) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.dm(10))
                        Text(verbatim: copied ? "Copied" : "Copy").font(.dm(10.5))
                    }
                    .foregroundStyle(Color.dmMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
                .demoClickTarget("chat:copy")
            }
            .padding(.horizontal, m.pt(12))
            .padding(.vertical, m.pt(6))
            .background(Color.white.opacity(0.03))
            ScrollView(.horizontal, showsIndicators: false) {
                CodeText(trimmedCode)
                    .highlightLanguage(HighlightLanguage(rawValue: language.lowercased()) ?? .plaintext)
                    .codeTextColors(.theme(.atomOne))
                    .font(.dm(12, design: .monospaced))
                    .lineSpacing(m.pt(3))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(m.pt(12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(hex: 0x0E1217), in: RoundedRectangle(cornerRadius: m.pt(DMRadius.tile)))
        .overlay(RoundedRectangle(cornerRadius: m.pt(DMRadius.tile)).stroke(Color.dmStroke, lineWidth: 0.5))
    }
}

/// Every message of a conversation, then the failure card or the stopped
/// note of its last turn.
struct ChatThreadView: View {
    let conversation: ChatConversation
    var fontSize: CGFloat = 13.5
    var compact = false
    var errorCard: (ChatFailure) -> AnyView = { _ in AnyView(EmptyView()) }
    @Environment(\.dmMetrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: m.pt(compact ? 10 : 22)) {
            ForEach(Array(conversation.messages.enumerated()), id: \.offset) { index, message in
                switch message.role {
                case .user:
                    ChatUserBubble(text: message.text, fontSize: fontSize, leadingSpace: compact ? 30 : 120)
                case .assistant:
                    ChatAnswerView(
                        message: message,
                        streaming: conversation.isStreaming && index == conversation.messages.count - 1,
                        fontSize: fontSize, status: conversation.status)
                }
            }
            if conversation.isStreaming, conversation.messages.last?.role == .user {
                ChatAnswerView(
                    message: ChatMessage(role: .assistant, text: ""), streaming: true, fontSize: fontSize,
                    status: conversation.status)
            }
            if let failure = conversation.failure {
                errorCard(failure)
            } else if conversation.wasStopped {
                HStack(spacing: m.pt(5)) {
                    Image(systemName: "stop.circle").font(.dm(10.5))
                    Text(verbatim: "Stopped").font(.dm(11))
                }
                .foregroundStyle(Color.dmMuted)
            }
        }
    }
}
