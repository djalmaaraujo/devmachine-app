import SwiftUI
import DevmachineCore

/// Where a message is typed: Return sends, ⇧Return starts a new line, Esc
/// stops an answer. The harness and workspace chips are pickers until the
/// chat's first message, then they only say what the chat uses.
struct ChatComposer: View {
    @Binding var text: String
    var placeholder = "Reply…"
    var minHeight: CGFloat = 46
    let harness: HarnessID
    let place: ChatPlace
    var locked = false
    var streaming = false
    var openPicker: ChatPicker?
    var togglePicker: (ChatPicker) -> Void = { _ in }
    var pickerItems: (ChatPicker) -> [ChatMenuItem] = { _ in [] }
    var mcp = false
    var toggleMCP: () -> Void = {}
    let send: () -> Void
    var stop: () -> Void = {}
    @Environment(\.dmMetrics) private var m
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !streaming && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: m.pt(10)) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.dm(13.5))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1...12)
                .focused($focused)
                .accessibilityLabel(placeholder.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
                .accessibilityHint("Return sends, Shift-Return starts a new line, Escape stops an answer")
                .frame(maxWidth: .infinity, minHeight: m.pt(minHeight), alignment: .topLeading)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        text += "\n"
                        return .handled
                    }
                    if canSend { send() }
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard streaming else { return .ignored }
                    stop()
                    return .handled
                }
                .demoClickTarget("chat:composer")
            HStack(spacing: m.pt(6)) {
                ChatPickerChip(
                    picker: .harness, harness: harness, place: place, locked: locked, open: openPicker == .harness,
                    items: { pickerItems(.harness) }, toggle: { togglePicker(.harness) })
                ChatPickerChip(
                    picker: .workspace, harness: harness, place: place, locked: locked,
                    open: openPicker == .workspace, items: { pickerItems(.workspace) },
                    toggle: { togglePicker(.workspace) })
                ChatMCPChip(isOn: mcp, toggle: toggleMCP)
                ChatReadOnlyLabel()
                    .padding(.leading, m.pt(4))
                    .demoClickTarget("chat:readonly")
                Spacer()
                ChatSendButton(enabled: canSend, stops: streaming) {
                    if streaming { stop() } else if canSend { send() }
                }
                .dmHelp(streaming ? "Stop (Esc)" : "Send (Return)")
            }
        }
        .padding(m.pt(14))
        .dmSurface(Color(hex: 0x1A2027), radius: DMRadius.card, style: .continuous)
        .shadow(color: .black.opacity(0.25), radius: m.pt(12), y: m.pt(4))
        .onAppear { if !DemoMode.isActive { focused = true } }
    }
}

/// The harness or workspace chip: a menu while the chat has no message,
/// then a plain label of what the chat keeps.
struct ChatPickerChip: View {
    let picker: ChatPicker
    let harness: HarnessID
    let place: ChatPlace
    var locked = false
    var open = false
    var height: CGFloat = 24
    var fontSize: CGFloat = 11.5
    let items: () -> [ChatMenuItem]
    let toggle: () -> Void

    private var name: String { picker == .harness ? "Coding agent" : "Workspace" }
    private var value: String { picker == .harness ? ChatHarness.title(harness) : ChatPlaceLabel.title(place) }

    var body: some View {
        Group {
            if locked {
                chip
                    .dmHelp(picker == .harness ? "A chat keeps its coding agent." : "A chat keeps its workspace.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(name)
                    .accessibilityValue(value)
            } else {
                ChatDropdown(
                    items: items(), accessibilityLabel: name, accessibilityValue: value,
                    accessibilityHint: "Opens the list to pick another", help: name, toggleDrawn: toggle
                ) { chip }
            }
        }
        .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [picker == .harness ? "harness" : "workspace": $0] }
        .demoClickTarget(picker == .harness ? "chat:harness" : "chat:workspace")
    }

    private var chip: some View {
        Group {
            if picker == .harness {
                ChatChip(harness: harness, title: value, menu: !locked, open: open, height: height, fontSize: fontSize)
            } else {
                ChatChip(systemImage: ChatPlaceLabel.symbol(place), title: value, menu: !locked, open: open,
                         height: height, fontSize: fontSize)
            }
        }
    }
}

/// Draws the open picker above its chip, and closes it on a click
/// anywhere else.
struct ChatPickerOverlay: ViewModifier {
    @ObservedObject var store: ChatStore
    let harness: HarnessID
    let place: ChatPlace
    var opensBelow = false
    let pickHarness: (HarnessID) -> Void
    let pickPlace: (ChatPlace) -> Void
    @Environment(\.dmMetrics) private var m

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ChatAnchorKey.self) { anchors in
            if DemoMode.isActive, let picker = store.openPicker,
               let anchor = anchors[picker == .harness ? "harness" : "workspace"] {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .onTapGesture { store.openPicker = nil }
                        if opensBelow {
                            ChatMenuCard(items: items(picker), width: 230, highlighted: highlighted(picker))
                                .offset(x: rect.minX - m.pt(6), y: rect.maxY + m.pt(6))
                        } else {
                            ChatMenuCard(items: items(picker), width: 230, highlighted: highlighted(picker))
                                .frame(height: max(0, rect.minY - m.pt(6)), alignment: .bottom)
                                .offset(x: rect.minX - m.pt(6))
                        }
                    }
                }
            }
        }
    }

    private func items(_ picker: ChatPicker) -> [ChatMenuItem] {
        Self.items(picker, store: store, harness: harness, place: place, pickHarness: pickHarness, pickPlace: pickPlace)
    }

    static func items(
        _ picker: ChatPicker, store: ChatStore, harness: HarnessID, place: ChatPlace,
        pickHarness: @escaping (HarnessID) -> Void, pickPlace: @escaping (ChatPlace) -> Void
    ) -> [ChatMenuItem] {
        switch picker {
        case .harness:
            return ChatMenus.harnesses(selected: harness, available: store.settings.harnesses) { id in
                pickHarness(id)
                store.openPicker = nil
            }
        case .workspace:
            return ChatMenus.places(selected: place, workspaces: store.workspaces, defaultPlace: store.defaultPlace) {
                pickPlace($0)
                store.openPicker = nil
            }
        }
    }

    private func highlighted(_ picker: ChatPicker) -> String {
        switch picker {
        case .harness: return "harness-" + harness.rawValue
        case .workspace: return "workspace-" + (place.workspaceName ?? "local")
        }
    }
}
