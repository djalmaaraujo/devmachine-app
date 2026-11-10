import SwiftUI
import AppKit
import DevmachineCore

/// The pane beside the terminal: the preview tabs, each a tab in one strip,
/// the way an editor keeps a browser next to a shell. A file is not here:
/// its tab is in the strip over the terminal and shows in its place.
struct DocumentPane: View {
    @Environment(\.dmMetrics) private var m
    @ObservedObject private var previews = PreviewStore.shared

    static func isVisible(previewTabs: Int) -> Bool {
        previewTabs > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.dmSidebarBg)
        .environment(\.colorScheme, .dark)
    }

    /// With no tab selected the last one opened shows, so the pane is never
    /// an empty strip.
    private var shownTab: PreviewTab? {
        previews.selectedTab ?? previews.tabs.last
    }

    @ViewBuilder
    private var content: some View {
        if let tab = shownTab {
            PreviewPaneView(tab: tab)
                .id(tab.id)
        }
    }

    /// A plain row, not a horizontal `ScrollView`: hit-tested in the running
    /// app, a click on a tab's close mark inside the scroll view landed on its
    /// clip view and never reached the button. Long titles shorten instead.
    private var strip: some View {
        HStack(spacing: m.space.xxs) {
            ForEach(previews.tabs) { tab in
                DocumentTabChip(
                    systemImage: "globe",
                    title: tab.title,
                    selected: shownTab?.id == tab.id,
                    closeHelp: "Close the preview",
                    select: { previews.select(tab.id) },
                    close: { previews.close(tab.id) })
            }
            Spacer(minLength: 0)
        }
        .background(Color.dmSidebarBg)
    }
}

/// The close mark sits beside the part that selects, not inside it, so the
/// tap that selects never competes with the button that closes.
struct DocumentTabChip: View {
    @Environment(\.dmMetrics) private var m
    let systemImage: String
    let title: String
    let selected: Bool
    let closeHelp: String
    let select: () -> Void
    let close: () -> Void
    /// A harness's own icon in place of the symbol, as the sidebar draws it.
    var image: NSImage? = nil
    var imageIsTemplate = false
    var iconColor = Color(hex: 0x5AA9E6)
    @State private var hovering = false

    static let maxTitleLength = 36

    static func shortened(_ title: String) -> String {
        title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }

    var body: some View {
        HStack(spacing: m.space.xxs) {
            HStack(spacing: m.space.sm) {
                icon
                Text(verbatim: Self.shortened(title))
                    .font(.dm(11.5))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, m.pt(10))
            .padding(.vertical, m.pt(7))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .contextMenu {
                Button(closeHelp, action: close)
            }
            DMIconButton(
                systemImage: "xmark", size: 9, weight: .semibold, tint: .white.opacity(0.45),
                hitSize: DMHitSize.compact, action: close)
                .help(closeHelp)
                .padding(.trailing, m.space.xs)
        }
        .background(selected ? Color.dmContentBg : (hovering ? Color.dmHover : Color.clear))
        // The strip runs under the toolbar band; without the claim a click on
        // the chip moved the window and never selected the tab.
        .claimsTitlebarClicks()
        .onHover { hovering = $0 }
        .onMiddleClick(while: hovering, perform: close)
    }

    @ViewBuilder
    private var icon: some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(imageIsTemplate ? .template : .original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(iconColor)
                .frame(width: m.pt(DMIconSize.sessionGlyph), height: m.pt(DMIconSize.sessionGlyph))
        } else {
            Image(systemName: systemImage)
                .font(.dm(10))
                .foregroundStyle(iconColor)
        }
    }
}

private extension View {
    /// A middle click closes a tab, as in a browser. A local event monitor
    /// that acts only while the pointer is over the chip, so nothing is laid
    /// over the close mark to take its clicks.
    func onMiddleClick(while active: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(MiddleClickModifier(active: active, action: action))
    }
}

private struct MiddleClickModifier: ViewModifier {
    let active: Bool
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, isActive in isActive ? install() : remove() }
            .onDisappear(perform: remove)
    }

    private func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
            guard event.buttonNumber == 2 else { return event }
            action()
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
