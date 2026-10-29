import SwiftUI
import AppKit
import DevmachineCore

/// The strip over the terminal: one tab per session of the workspace on
/// screen opened this run, with its harness's icon, and one per file looked
/// at from one of them, then +. Another workspace's tabs wait for it; Home
/// shows none. Closing a tab (its ×, ⌘W) takes it off the strip and nothing
/// else; the session goes on running and stays in the sidebar.
struct CenterTabStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.dmMetrics) private var m
    @Environment(\.collapsedSidebarButtonFrame) private var toggleFrame
    @Environment(\.titleLine) private var titleLine

    /// The tab row, in points at 100%.
    static let rowHeight: CGFloat = 34
    static let gapAfterToggle: CGFloat = 8

    static func shows(enabled: Bool, mode: AppMode) -> Bool {
        enabled && mode == .code
    }

    /// With the sidebar closed the window buttons and the sidebar toggle sit
    /// over the strip's corner, so its tabs start after the toggle and the
    /// strip grows so that its row centres on the buttons' line.
    static func leadingInset(toggle: CGRect?, gap: CGFloat) -> CGFloat {
        guard let toggle else { return 0 }
        return toggle.maxX + gap
    }

    static func stripHeight(toggle: CGRect?, titleLine: CGFloat, row: CGFloat) -> CGFloat {
        guard toggle != nil else { return row }
        return max(row, titleLine * 2)
    }

    static func rowTop(row: CGFloat, strip: CGFloat) -> CGFloat {
        max(0, (strip - row) / 2)
    }

    static func fileIcon(path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": return "photo"
        default: return "doc.text"
        }
    }

    private var row: CGFloat { m.pt(Self.rowHeight) }
    private var strip: CGFloat { Self.stripHeight(toggle: toggleFrame, titleLine: titleLine, row: row) }

    var body: some View {
        HStack(spacing: m.space.xxs) {
            ForEach(model.visibleTabs, id: \.self) { tab in
                chip(tab)
            }
            DMIconButton(systemImage: "plus", size: 11, hitSize: DMHitSize.compact) { model.requestQuickSession() }
                .dmHelp("New session (⌘N)")
                .accessibilityLabel("New session")
                .padding(.leading, m.space.xs)
            Spacer(minLength: 0)
        }
        .frame(height: row)
        .padding(.leading, Self.leadingInset(toggle: toggleFrame, gap: m.pt(Self.gapAfterToggle)))
        .padding(.top, Self.rowTop(row: row, strip: strip))
        .frame(maxWidth: .infinity, minHeight: strip, maxHeight: strip, alignment: .topLeading)
        .background(Color.dmSidebarBg)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open tabs")
    }

    @ViewBuilder
    private func chip(_ tab: CenterTab) -> some View {
        let selected = model.isSelected(tab: tab)
        switch tab {
        case let .session(item):
            let icon = harnessIcon(for: item)
            DocumentTabChip(
                systemImage: "apple.terminal",
                title: model.title(for: tab),
                selected: selected,
                closeHelp: "Close the tab (⌘W; the session keeps running)",
                select: { model.select(tab: tab) },
                close: { model.close(tab: tab) },
                image: icon?.image,
                imageIsTemplate: icon?.isTemplate ?? false,
                iconColor: Color.dmRowText.opacity(0.8))
                .demoClickTarget("tab:session:\(model.title(for: tab))")
        case let .file(_, path):
            DocumentTabChip(
                systemImage: Self.fileIcon(path: path),
                title: model.title(for: tab),
                selected: selected,
                closeHelp: "Close the file tab",
                select: { model.select(tab: tab) },
                close: { model.close(tab: tab) })
                .dmHelp(path)
        case let .schema(_, folder):
            DocumentTabChip(
                systemImage: "cylinder.split.1x2",
                title: model.title(for: tab),
                selected: selected,
                closeHelp: "Close the schema tab",
                select: { model.select(tab: tab) },
                close: { model.close(tab: tab) })
                .dmHelp(folder ?? "Database schema of the session's folder")
        }
    }

    private func harnessIcon(for item: SidebarItem) -> HarnessIcon? {
        guard let id = model.harnessBadges(for: item).first?.id else { return nil }
        return HarnessIconLibrary.bundled.icon(for: id, style: settingsStore.settings?.harnessIconStyle ?? .color)
    }
}
