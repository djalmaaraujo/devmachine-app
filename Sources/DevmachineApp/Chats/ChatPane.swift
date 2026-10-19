import SwiftUI
import DevmachineCore

/// One open conversation: title and chips, the thread, and the composer.
struct ChatPane: View {
    let chatID: String
    @ObservedObject var store: ChatStore
    var rename: (String) -> Void = { _ in }
    var delete: (String) -> Void = { _ in }
    @Environment(\.dmMetrics) private var m
    @State private var reply = ""

    private var conversation: ChatConversation { store.conversation(chatID) }
    private var record: ChatRecord? { store.record(chatID) }
    private var harness: HarnessID { record?.harness ?? store.draftHarness }
    private var place: ChatPlace { record?.place ?? store.draftPlace }
    private static let bottom = "chat-bottom"

    /// Grows with every message, delta and failure, so the thread follows
    /// the answer as it arrives.
    private var progress: Int {
        conversation.messages.count * 1_000_000 + (conversation.messages.last?.text.count ?? 0)
            + (conversation.failure == nil ? 0 : 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ChatThreadView(conversation: conversation) { failure in
                            AnyView(ChatErrorCard(failure: failure, chatID: chatID, harness: harness, place: place))
                        }
                        .frame(maxWidth: m.pt(760), alignment: .leading)
                        .padding(.horizontal, m.pt(32))
                        .padding(.vertical, m.pt(24))
                        .frame(maxWidth: .infinity)
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: progress) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            ChatComposer(
                text: $reply, harness: harness, place: place, locked: true, streaming: conversation.isStreaming,
                mcp: store.usesMCP(chatID),
                toggleMCP: { store.setMCP(!store.usesMCP(chatID), chat: chatID) },
                send: {
                    if store.send(reply, toChat: store.current(chatID)) != nil { reply = "" }
                },
                stop: { store.stop(chatID) })
                .frame(maxWidth: m.pt(760))
                .padding(.horizontal, m.pt(32))
                .padding(.bottom, m.pt(20))
                .frame(maxWidth: .infinity)
        }
        .background(Color.dmContentBg)
        .onAppear { store.warmChat(chatID) }
        .onChange(of: chatID) { _, id in store.warmChat(id) }
    }

    private var header: some View {
        HStack(spacing: m.pt(8)) {
            Text(verbatim: record?.title ?? "")
                .font(.dm(14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer().frame(width: m.pt(6))
            ChatChip(harness: harness, title: ChatHarness.title(harness))
            ChatChip(systemImage: ChatPlaceLabel.symbol(place), title: ChatPlaceLabel.title(place))
            if let folder = record?.folder, !folder.isEmpty, !place.isLocalChat {
                ChatChip(systemImage: "folder", title: folder)
            }
            ChatChip(systemImage: "eye", title: "Read only", tint: Color.dmMuted)
                .dmHelp("Chats can read files and run read-only commands. They never edit files.")
            Spacer()
            Menu {
                Button("Rename…") { rename(chatID) }
                Button("Delete", role: .destructive) { delete(chatID) }
            } label: {
                Image(systemName: "ellipsis").font(.dm(13)).foregroundStyle(Color.dmMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(chatID.hasPrefix(ChatStore.pendingPrefix))
            .dmHelp("Rename or delete this chat")
            .accessibilityLabel("Chat actions")
        }
        .padding(.horizontal, m.pt(20))
        .padding(.top, m.pt(12))
        .padding(.bottom, m.pt(10))
        .background(Color.dmContentBg)
    }
}

extension ChatPlace {
    var isLocalChat: Bool { self == .local }
}

/// "What can I help you with?": the first message of a new chat, with its
/// harness and workspace still open to choose.
struct NewChatView: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dmMetrics) private var m

    private static let suggestions: [(title: String, text: String)] = [
        ("Explain a file", "Explain what this file does: "),
        ("Find where something is defined", "Where is this defined: "),
        ("Draft a commit message", "Draft a commit message for these changes: "),
    ]

    var body: some View {
        VStack(spacing: m.pt(26)) {
            Spacer()
            VStack(spacing: m.pt(8)) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.dm(26))
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: "What can I help you with?")
                    .font(.dm(26, weight: .semibold))
                    .foregroundStyle(.white)
                Text(verbatim: "Ask Claude or Codex on your workspace. Chats can read your files, never change them.")
                    .font(.dm(12.5))
                    .foregroundStyle(Color.dmMuted)
            }
            ChatComposer(
                text: $store.draft.text, placeholder: "Ask anything…", minHeight: 70,
                harness: store.draftHarness, place: store.draftPlace, openPicker: store.openPicker,
                togglePicker: { picker in store.openPicker = store.openPicker == picker ? nil : picker },
                pickerItems: { picker in
                    ChatPickerOverlay.items(
                        picker, store: store, harness: store.draftHarness, place: store.draftPlace,
                        pickHarness: { store.draft.harness = $0 }, pickPlace: { store.draft.place = $0 })
                },
                mcp: store.usesMCP(nil),
                toggleMCP: { store.setMCP(!store.usesMCP(nil), chat: nil) },
                send: { store.sendFromPane(store.draft.text) })
                .frame(width: m.pt(680))
            if let failure = store.listFailure, failure.kind == .needsNewerCLI {
                ChatErrorCard(
                    failure: failure, chatID: "", harness: store.draftHarness, place: store.draftPlace)
                    .frame(width: m.pt(680))
            } else {
                HStack(spacing: m.pt(8)) {
                    ForEach(Self.suggestions, id: \.title) { suggestion in
                        Button { store.draft.text = suggestion.text } label: {
                            Text(verbatim: suggestion.title)
                                .font(.dm(11.5))
                                .foregroundStyle(Color.dmRowText)
                                .padding(.horizontal, m.pt(10))
                                .padding(.vertical, m.pt(5))
                                .dmSurface(Color.white.opacity(0.05), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Starts the message for you")
                    }
                }
            }
            recent
                .frame(width: m.pt(680))
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dmContentBg)
        .modifier(ChatPickerOverlay(
            store: store, harness: store.draftHarness, place: store.draftPlace, opensBelow: true,
            pickHarness: { store.draft.harness = $0 }, pickPlace: { store.draft.place = $0 }))
        .onAppear { store.prewarm(store.draftSpec) }
        .onChange(of: store.draftSpec) { _, spec in store.prewarm(spec) }
    }

    @ViewBuilder
    private var recent: some View {
        let chats = Array(store.visibleChats.prefix(3))
        if !chats.isEmpty {
            VStack(alignment: .leading, spacing: m.pt(2)) {
                DMSectionLabel(text: "RECENT")
                    .padding(.horizontal, m.pt(10))
                    .padding(.bottom, m.pt(4))
                ForEach(chats) { chat in
                    HStack(spacing: m.pt(10)) {
                        ChatHarnessGlyph(harness: chat.harness, size: 13)
                        Text(verbatim: chat.title).font(.dm(12.5)).foregroundStyle(Color.dmRowText).lineLimit(1)
                        Spacer()
                        Text(verbatim: ChatPlaceLabel.title(chat.place)).font(.dm(11)).foregroundStyle(Color.dmMuted)
                        Group {
                            if store.isAnswering(chat.id) {
                                ChatSpinner(size: 10)
                            } else {
                                Text(verbatim: ChatGrouping.age(of: chat.updatedAt, now: Date()))
                                    .font(.dm(11)).foregroundStyle(Color.dmMuted)
                            }
                        }
                        .frame(width: m.pt(30), alignment: .trailing)
                    }
                    .padding(.horizontal, m.pt(10))
                    .padding(.vertical, m.pt(7))
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: m.pt(DMRadius.row)))
                    .contentShape(Rectangle())
                    .onTapGesture { store.select(chat.id) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ChatAccessibility.rowLabel(chat, answering: store.isAnswering(chat.id)))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { store.select(chat.id) }
                }
            }
        }
    }
}
