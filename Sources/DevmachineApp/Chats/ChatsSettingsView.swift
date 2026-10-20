import AppKit
import SwiftUI
import DevmachineCore

/// Settings → Chats. Saved with the page's Save, like every other section:
/// where chats run goes to the CLI's config.yml, the rest to the app.
struct ChatsSettingsView: View {
    @Binding var chats: ChatSettings
    @Binding var config: ChatCLIConfig
    let workspaces: [String]
    @Environment(\.dmMetrics) private var m

    private var defaultPlace: ChatPlace { config.defaultPlace(workspaces: workspaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: m.pt(28)) {
            subsection("Where chats run") {
                field("Default workspace",
                      hint: "New chats start here. A chat can pick another workspace before the first message.") {
                    Menu {
                        ForEach(workspaces, id: \.self) { name in
                            Button(name) { config.defaultWorkspace = name }
                        }
                        Divider()
                        Button(ChatPlaceLabel.thisMac) { config.defaultWorkspace = ChatRecord.localWorkspace }
                    } label: {
                        ChatChip(systemImage: ChatPlaceLabel.symbol(defaultPlace), title: ChatPlaceLabel.title(defaultPlace),
                                 menu: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                field("Chats folder",
                      hint: "The folder a chat without a project runs in, on its workspace. Created on first use.") {
                    TextField(ChatSettings.defaultFolder, text: $config.folder)
                        .font(.dm(DMMetrics.baseFontSize, design: .monospaced))
                        .dmField()
                        .frame(width: m.pt(260))
                }
            }
            subsection("Quick chat") {
                field("Global shortcut",
                      hint: "Opens the quick chat panel from any app. Click and press a new shortcut to change it.") {
                    ChatShortcutRecorder(hotkey: $chats.hotkey)
                }
                toggle("Show in the menu bar",
                       detail: "New chat and the three latest chats at the top of the menu bar panel.",
                       isOn: $chats.showsInMenuBar)
            }
            subsection("Coding agents") {
                ForEach(ChatHarness.supported, id: \.self) { harness in
                    harnessToggle(harness)
                }
                field("New chats start with", hint: "A chat can pick the other one before the first message.") {
                    Menu {
                        ForEach(chats.harnesses, id: \.self) { harness in
                            Button(ChatHarness.title(harness)) { config.harness = harness }
                        }
                    } label: {
                        ChatChip(harness: config.harness, title: ChatHarness.title(config.harness), menu: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                toggle("Load MCP servers in new chats",
                       detail: "Off, a chat starts several seconds faster. A chat can turn them on with its MCP chip.",
                       isOn: $config.mcp)
                HStack(spacing: m.pt(6)) {
                    Image(systemName: "ellipsis.circle").font(.dm(11)).foregroundStyle(Color.dmMuted)
                    Text(verbatim: "More coming soon").font(.dm(11)).foregroundStyle(Color.dmMuted)
                }
            }
            subsection("Read only") {
                HStack(alignment: .top, spacing: m.pt(10)) {
                    Image(systemName: "lock.fill").font(.dm(12)).foregroundStyle(Color.dmMuted)
                    VStack(alignment: .leading, spacing: m.pt(3)) {
                        Text(verbatim: "Chats can read files and run read-only commands. They never edit files.")
                            .font(.dm(12)).foregroundStyle(.white.opacity(0.85))
                        Text(verbatim: "This is fixed. To change code, start a session in Code.")
                            .font(.dm(10)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .padding(m.pt(12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .dmSurface(Color.white.opacity(0.03), radius: DMRadius.tile)
            }
        }
    }

    private func subsection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: m.space.lg) {
            Text(verbatim: title).font(.dm(13, weight: .semibold)).foregroundStyle(.white)
            content()
        }
    }

    private func field(_ title: String, hint: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: m.pt(5)) {
            Text(verbatim: title).font(.dm(11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            control()
            Text(verbatim: hint).font(.dm(11)).foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: m.pt(2)) {
                Text(verbatim: title).font(.dm(12)).foregroundStyle(.white.opacity(0.85))
                Text(verbatim: detail).font(.dm(10)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: m.pt(520))
    }

    private func harnessToggle(_ harness: HarnessID) -> some View {
        let isOn = Binding(
            get: { chats.enabledHarnesses.contains(harness) },
            set: { on in
                var enabled = chats.enabledHarnesses.filter { $0 != harness }
                if on { enabled.append(harness) }
                chats.enabledHarnesses = ChatHarness.supported.filter(enabled.contains)
            })
        return Toggle(isOn: isOn) {
            HStack(spacing: m.pt(8)) {
                ChatHarnessGlyph(harness: harness, size: 16)
                VStack(alignment: .leading, spacing: m.pt(2)) {
                    Text(verbatim: ChatHarness.title(harness)).font(.dm(12)).foregroundStyle(.white.opacity(0.85))
                    Text(verbatim: Self.harnessDetail(harness)).font(.dm(10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: m.pt(520))
        .disabled(isOn.wrappedValue && chats.harnesses == [harness])
    }

    static func harnessDetail(_ harness: HarnessID) -> String {
        switch harness {
        case .claude: return "Runs the claude CLI you are logged in to, in plan mode."
        case .codex: return "Runs codex exec you are logged in to, in a read-only sandbox."
        default: return ""
        }
    }
}

/// Click, then press the new shortcut. Esc gives up; the cross clears it.
struct ChatShortcutRecorder: View {
    @Binding var hotkey: ChatHotkey?
    @Environment(\.dmMetrics) private var m
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: m.pt(4)) {
            if recording {
                Text(verbatim: "Press a shortcut…").font(.dm(11.5)).foregroundStyle(Color.dmMuted)
            } else if let hotkey {
                ForEach(Array(hotkey.keyCaps.enumerated()), id: \.offset) { _, key in DMKeyCap(key: key) }
            } else {
                Text(verbatim: "None").font(.dm(11.5)).foregroundStyle(Color.dmMuted)
            }
            if hotkey != nil, !recording {
                DMButton(icon: "xmark.circle.fill", label: "Clear the shortcut", size: .small) { hotkey = nil }
            }
        }
        .padding(.horizontal, m.pt(8))
        .padding(.vertical, m.pt(4))
        .frame(minHeight: m.pt(28))
        .dmSurface(Color.dmSelection, radius: DMRadius.row,
                   stroke: recording ? Color.accentColor : Color.accentColor.opacity(0.4))
        .contentShape(Rectangle())
        .onTapGesture { recording ? stop() : start() }
        .onDisappear { stop() }
        .dmHelp("Click and press a new shortcut")
    }

    private func start() {
        recording = true
        QuickChatPanelController.shared.suspendHotkey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if let recorded = ChatHotkey.recorded(
                keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event.modifierFlags),
                characters: event.charactersIgnoringModifiers) {
                hotkey = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { QuickChatPanelController.shared.suspendHotkey(false) }
        recording = false
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ChatHotkey.Modifiers {
        var modifiers: ChatHotkey.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}
