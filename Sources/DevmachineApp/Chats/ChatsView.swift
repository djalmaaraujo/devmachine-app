import SwiftUI
import DevmachineCore

/// Chats mode: the conversation list and the open chat, in the place
/// Code mode puts the sidebar and the terminal.
struct ChatsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: ChatStore
    @Environment(\.dmMetrics) private var m
    @State private var renaming: String?
    @State private var newTitle = ""
    @State private var deleting: String?

    var body: some View {
        HStack(spacing: 0) {
            if !model.sidebarCollapsed {
                ChatsSidebar(store: store, rename: beginRename, delete: { deleting = $0 })
                    .modifier(SidebarUnderTitlebar())
                    .frame(width: m.pt(model.sidebarWidth))
                Color.dmSidebarBg.frame(width: m.pt(6))
            }
            Group {
                if let id = store.selectedID {
                    ChatPane(chatID: id, store: store, rename: beginRename, delete: { deleting = $0 })
                        .id(id)
                } else {
                    NewChatView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.dmContentBg.ignoresSafeArea())
        }
        .background(Color.dmSidebarBg)
        .task { await store.refresh() }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let id = renaming { Task { await store.rename(id, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete this chat? Its messages on this Mac are removed.",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deleting { Task { await store.delete(id) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private func beginRename(_ id: String) {
        newTitle = store.record(id)?.title ?? ""
        renaming = id
    }
}

struct ChatsSidebar: View {
    @ObservedObject var store: ChatStore
    let rename: (String) -> Void
    let delete: (String) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dmMetrics) private var m
    @State private var query = ""

    private var groups: [ChatGroup] {
        ChatGrouping.groups(ChatGrouping.filter(store.visibleChats, query: query), now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: m.pt(10)) {
                SidebarModeHeader(refresh: { Task { await store.refresh() } })
                SidebarNewRow(title: "New chat", systemImage: "square.and.pencil", shortcut: "⌘N",
                              selected: store.selectedID == nil) { store.startNewChat() }
                    .demoClickTarget("chats:new")
            }
            .modifier(SidebarHeaderTop())
            DMSearchField(prompt: "Search chats", text: $query)
                .padding(.horizontal, m.pt(10))
                .frame(height: m.pt(30))
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: m.pt(DMRadius.control)))
                .padding(.horizontal, m.pt(10))
                .padding(.top, m.pt(8))
                .padding(.bottom, m.pt(6))
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(groups) { group in
                        Text(verbatim: group.title)
                            .font(.dm(11, weight: .medium))
                            .foregroundStyle(Color.dmMuted)
                            .padding(.horizontal, m.pt(16))
                            .padding(.top, m.pt(14))
                            .padding(.bottom, m.pt(4))
                        ForEach(group.chats) { chat in
                            row(chat)
                        }
                    }
                    if groups.isEmpty, store.hasLoaded {
                        Text(verbatim: query.isEmpty ? "No chats yet" : "No chat matches")
                            .font(.dm(12))
                            .foregroundStyle(Color.dmMuted)
                            .padding(.horizontal, m.pt(16))
                            .padding(.top, m.pt(14))
                    }
                }
                .padding(.bottom, m.pt(10))
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .accessibilityLabel("Chats")
            .accessibilityHint("Up and down arrows move between chats")
            footer
        }
        .background(Color.dmSidebarBg)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let ids = groups.flatMap(\.chats).map(\.id)
        guard let next = ChatListNavigation.neighbor(of: store.selectedID, in: ids, step: step) else { return .ignored }
        store.select(next)
        return .handled
    }

    private func row(_ chat: ChatRecord) -> some View {
        HStack(spacing: m.pt(8)) {
            Text(verbatim: chat.title)
                .font(.dm(13))
                .foregroundStyle(Color.dmRowText)
                .lineLimit(1)
            Spacer(minLength: m.pt(6))
            if store.isAnswering(chat.id) {
                ChatSpinner(size: 11)
            } else if chat.place != store.defaultPlace {
                Text(verbatim: ChatPlaceLabel.title(chat.place)).font(.dm(10.5)).foregroundStyle(Color.dmMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, m.row.horizontal)
        .padding(.vertical, m.row.vertical)
        .background(DMRowBackground(selected: chat.id == store.selectedID))
        .padding(.horizontal, m.row.outer)
        .contentShape(Rectangle())
        .onTapGesture { store.select(chat.id) }
        .contextMenu {
            Button("Rename…") { rename(chat.id) }
            Button("Delete", role: .destructive) { delete(chat.id) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatAccessibility.rowLabel(chat, answering: store.isAnswering(chat.id)))
        .accessibilityAddTraits(chat.id == store.selectedID ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.select(chat.id) }
        .accessibilityAction(named: "Rename") { rename(chat.id) }
        .accessibilityAction(named: "Delete") { delete(chat.id) }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("chart.bar") { model.showPage(.stats) }
                .dmHelp("Stats")
            if model.hasCaddyMachine {
                footerButton("globe") { model.showPage(.subdomains) }
                    .dmHelp("Published apps")
            }
            footerButton("gearshape") { model.openSettings(.chats) }
                .dmHelp("Settings (⌘,)")
        }
        .padding(.horizontal, m.space.lg)
        .padding(.vertical, m.space.md)
    }

    private func footerButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        DMIconButton(
            systemImage: systemImage, size: DMMetrics.baseFontSize, hitSize: DMHitSize.footer, fillsWidth: true,
            action: action)
    }
}
