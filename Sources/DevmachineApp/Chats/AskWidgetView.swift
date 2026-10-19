import SwiftUI
import DevmachineCore

/// ASK in the Context sidebar: a side question about the selected session,
/// answered without typing into it.
struct AskWidgetView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var asks = AskStore.shared
    @ObservedObject private var context: ContextStore
    @Environment(\.dmMetrics) private var m

    init(context: ContextStore) {
        self.context = context
    }

    private var key: AskSessionKey? { model.askSessionKey }

    private var mode: AskMode {
        let detected = context.state?.harness
            ?? model.selectedSessionHarnessIDs.first { ChatHarness.supported.contains($0) }
            ?? model.selectedSessionHarnessIDs.first
        return AskMode(harness: detected)
    }

    var body: some View {
        Group {
            if let key {
                section(key)
            } else {
                StackEmptyWidgetHeader()
            }
        }
        .onAppear { if let key { warm(key) } }
        .onDisappear { if let key { store.closeAsk(key) } }
        .onChange(of: key) { old, new in
            if let old { store.closeAsk(old) }
            if let new { warm(new) }
        }
    }

    /// One `chat ask --serve` per visible Ask section, so a question does
    /// not wait for the harness to start.
    private func warm(_ key: AskSessionKey) {
        guard case let .supported(harness) = mode else { return }
        store.warmAsk(key, harness: harness, folder: model.askSessionFolder, chatID: asks.threadID(for: key, in: store))
    }

    private func section(_ key: AskSessionKey) -> some View {
        let threadID = asks.threadID(for: key, in: store)
        let conversation = threadID.map(store.conversation)
        let hasThread = conversation.map { !$0.messages.isEmpty } ?? false
        return DMSection(
            contentSpacing: 10,
            padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14),
            label: { DMSectionLabel(text: "ASK") },
            trailing: {
                if hasThread {
                    DMButton("Clear", variant: .ghost, size: .small) {
                        Task {
                            guard await asks.clear(key, store: store) else { return }
                            store.closeAsk(key)
                            warm(key)
                        }
                    }
                    .disabled(conversation?.isStreaming == true)
                    .demoClickTarget("ask:clear")
                    .dmHelp("Delete this Ask thread and start a new one")
                    .accessibilityLabel("Clear the Ask thread")
                    .accessibilityHint("Deletes this Ask thread and starts a new one")
                }
                StackHeaderControls()
            }
        ) {
            VStack(alignment: .leading, spacing: m.pt(10)) {
                HStack(spacing: m.pt(5)) {
                    if let harness = mode.harness { ChatHarnessGlyph(harness: harness, size: 11) }
                    Text(verbatim: mode.subtitle).font(.dm(10.5)).foregroundStyle(Color.dmMuted)
                }
                if let conversation, let threadID, !conversation.messages.isEmpty || conversation.isStreaming {
                    ChatThreadView(conversation: conversation, fontSize: 12, compact: true) { failure in
                        AnyView(ChatErrorCard(
                            failure: failure, chatID: threadID, harness: mode.harness ?? .claude, place: key.place,
                            compact: true))
                    }
                    if let excerpts = conversation.record?.excerpts, excerpts > 0, !conversation.isStreaming {
                        HStack(spacing: m.pt(4)) {
                            Image(systemName: "text.magnifyingglass").font(.dm(9.5))
                            Text(verbatim: excerpts == 1
                                ? "Based on 1 excerpt from the transcript"
                                : "Based on \(excerpts) excerpts from the transcript")
                                .font(.dm(10.5))
                        }
                        .foregroundStyle(Color.dmMuted)
                    }
                }
                if let failure = asks.clearFailures[key] {
                    HStack(alignment: .top, spacing: m.pt(5)) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.dm(10))
                        Text(verbatim: "Could not delete this thread: \(failure)").font(.dm(10.5))
                    }
                    .foregroundStyle(Color.red)
                    .accessibilityElement(children: .combine)
                }
                if mode.isSupported {
                    input(key, streaming: conversation?.isStreaming == true, threadID: threadID)
                    Text(verbatim: "Asking never types into the session.")
                        .font(.dm(10))
                        .foregroundStyle(Color.dmMuted)
                }
            }
            .task(id: threadID) { if let threadID { store.loadIfNeeded(threadID) } }
            .task { await store.refresh() }
        }
        .demoClickTarget("context:ask")
    }

    private func input(_ key: AskSessionKey, streaming: Bool, threadID: String?) -> some View {
        HStack(spacing: m.pt(6)) {
            TextField("Ask about this session…", text: question(key))
                .textFieldStyle(.plain)
                .accessibilityLabel("Ask about this session")
                .accessibilityHint("Return asks; the session is not interrupted")
                .font(.dm(12))
                .onSubmit { send(key) }
                .onKeyPress(.escape) {
                    guard streaming, let threadID else { return .ignored }
                    store.stop(threadID)
                    return .handled
                }
            ChatSendButton(
                size: 20, enabled: !(asks.drafts[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                stops: streaming
            ) {
                if streaming, let threadID { store.stop(threadID) } else { send(key) }
            }
            .dmHelp(streaming ? "Stop (Esc)" : "Ask (Return)")
        }
        .padding(.leading, m.pt(10))
        .padding(.trailing, m.pt(5))
        .padding(.vertical, m.pt(5))
        .dmSurface(Color.dmSelection, radius: DMRadius.pill, style: .continuous)
        .demoClickTarget("ask:input")
    }

    private func question(_ key: AskSessionKey) -> Binding<String> {
        Binding(get: { asks.drafts[key] ?? "" }, set: { asks.drafts[key] = $0 })
    }

    private func send(_ key: AskSessionKey) {
        let text = asks.drafts[key] ?? ""
        if asks.ask(text, key: key, mode: mode, folder: model.askSessionFolder, store: store) != nil {
            asks.drafts[key] = nil
        }
    }
}
