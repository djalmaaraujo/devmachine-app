import SwiftUI
import AppKit
import HarnessUsageKit
import DevmachineCore

enum MenuBarTab: String, CaseIterable, Identifiable {
    case pullRequests
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pullRequests: return "Pull Requests"
        case .usage: return "Usage"
        }
    }

    var systemImage: String {
        switch self {
        case .pullRequests: return "arrow.triangle.pull"
        case .usage: return "gauge.with.dots.needle.bottom.50percent"
        }
    }

    init?(viewKind: String) {
        switch viewKind {
        case "app.pull-requests-panel": self = .pullRequests
        case "app.usage-panel": self = .usage
        default: return nil
        }
    }

    var defaultEntryID: String {
        switch self {
        case .pullRequests: return "pull-requests-panel"
        case .usage: return "usage-panel"
        }
    }
}

enum MenuBarSizing {
    static func width(
        for _: MenuBarTab, usageColumns _: Int, available: CGFloat
    ) -> CGFloat {
        min(776, max(320, available - 32))
    }

    static func height(for _: MenuBarTab) -> CGFloat {
        640
    }

    static func columnWidth(panelWidth: CGFloat, usageColumns: Int) -> CGFloat {
        let columns = max(1, usageColumns)
        if columns == 1 { return panelWidth }
        let dividers = CGFloat(max(0, columns - 1))
        return min(UsagePanelMetrics.columnWidth, (panelWidth - dividers) / CGFloat(columns))
    }
}

struct MenuBarPanel: View {
    @Environment(\.dmMetrics) private var m
    @EnvironmentObject var prStore: PRStore
    @EnvironmentObject var usageStore: HarnessUsageStore
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var menubar: MenubarController
    @Environment(\.harnessSettingsFacade) private var harnessSettingsFacade
    @Environment(\.openWindow) private var openWindow
    @State private var tab: MenubarTabID?
    @State private var editing = false
    private let initialTab: MenuBarTab
    private let height: CGFloat?

    init(initialTab: MenuBarTab = .pullRequests, height: CGFloat? = nil) {
        self.initialTab = initialTab
        self.height = height
        _tab = State(initialValue: .entry(initialTab.defaultEntryID))
    }

    private var panelWidth: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return MenuBarSizing.width(
            for: initialTab,
            usageColumns: usageStore.states.count,
            available: screen?.visibleFrame.width ?? 1_200)
    }

    private var approvals: [MenubarApproval] { menubar.approvals }

    private func makeTabs() -> [MenubarTab] {
        let panel = menubar.panel
        return MenubarTabs.make(
            board: panel.board, resolve: { panel.resolution(of: $0) }, catalog: panel.catalog.catalog,
            hasApprovals: !approvals.isEmpty)
    }

    var body: some View {
        let tabs = makeTabs()
        VStack(spacing: 0) {
            banners
            if editing {
                MenubarEditView(slots: menubar.slots, panel: menubar.panel)
            } else {
                tabBar(tabs)
                content(tabs)
            }
            footer
                .background(Color.dmBand)
        }
        .frame(width: panelWidth)
        .frame(height: height ?? MenuBarSizing.height(for: initialTab))
        .background(Color.dmContentBg)
        .background(MenubarPanelWindowWatch { signal($0) })
        .animation(.easeInOut(duration: 0.15), value: tab)
        .onAppear { signal(.appeared) }
        .onDisappear { signal(.disappeared) }
        .onChange(of: tabs) { _, next in tab = MenubarTabs.keeping(tab, in: next) }
        .onChange(of: tab) { _, next in menubar.showTab(MenubarTabs.shownEntry(next, editing: editing)) }
        .onChange(of: editing) { _, now in menubar.showTab(MenubarTabs.shownEntry(tab, editing: now)) }
    }

    /// `onAppear` and `onDisappear` are not reliable for a `MenuBarExtra`
    /// window kept alive between opens, so its key state counts too; the
    /// first signal of an open or a close acts, the rest change nothing.
    private func signal(_ signal: MenubarPanelSignal) {
        guard let open = MenubarPanelPresence.change(after: signal, isOpen: menubar.isPanelOpen) else { return }
        if open {
            tab = MenubarTabs.opening(makeTabs(), preferred: initialTab.defaultEntryID)
            menubar.showTab(MenubarTabs.shownEntry(tab, editing: editing))
            menubar.setPanelOpen(true)
        } else {
            editing = false
            menubar.setPanelOpen(false)
        }
    }

    @ViewBuilder
    private func tabBar(_ tabs: [MenubarTab]) -> some View {
        if tabs.count > 1 {
            DMTabStrip(
                tabs: tabs.map(\.id),
                selection: Binding(get: { tab ?? tabs[0].id }, set: { tab = $0 }),
                title: { id in tabs.first { $0.id == id }?.title ?? "" },
                systemImage: { id in tabs.first { $0.id == id }?.systemImage }
            )
            .padding(m.space.md)
        } else if let onlyTab = tabs.first {
            Text(verbatim: onlyTab.title)
                .font(.dm(13, weight: .semibold))
                .foregroundStyle(Color.dmRowText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(m.pt(10))
        }
    }

    @ViewBuilder
    private func content(_ tabs: [MenubarTab]) -> some View {
        switch tab {
        case .approvals?:
            MenubarApprovalsView(approvals: approvals, panelWidth: panelWidth, sources: menubar.slots.sources)
        case let .entry(id)?:
            if let entry = menubar.panel.board.entries.first(where: { $0.id == id }) {
                MenubarTabContent(
                    entry: entry, title: tabs.first { $0.id == .entry(id) }?.title ?? "", panelWidth: panelWidth,
                    panel: menubar.panel)
                .id(entry.id)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case nil:
            Text(verbatim: "No widgets here yet. Use Edit to add one.")
                .foregroundStyle(Color.dmMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var banners: some View {
        ForEach([menubar.slots, menubar.panel], id: \.surface) { board in
            if let problem = board.problem {
                DMBanner(
                    message: StackBoardCopy.invalid(
                        file: StackArea.fileName(board.surface), problem: problem, keepsLastGood: board.store?.board != nil),
                    lineLimit: 3
                ) {
                    DMButton("Read again", variant: .ghost, size: .small) { board.reload() }
                }
                .padding(.horizontal, m.pt(10))
                .padding(.top, m.space.sm)
            } else if let error = board.writeError {
                DMBanner(message: StackBoardCopy.saveFailed(file: StackArea.fileName(board.surface), error: error), lineLimit: 3) {
                    EmptyView()
                }
                .padding(.horizontal, m.pt(10))
                .padding(.top, m.space.sm)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: m.pt(14)) {
            footerButton("macwindow", help: "Open") {
                openWindow(id: "main")
            }
            footerButton("chart.bar", help: "Stats") {
                openWindow(id: "main")
                model.showPage(.stats)
            }
            footerButton("clock", help: "Scheduled") {
                openWindow(id: "main")
                model.showPage(.scheduled)
            }
            footerButton("globe", help: "Published apps") {
                openWindow(id: "main")
                model.showPage(.subdomains)
            }
            DMButton(icon: "eyedropper", label: "Pick a color", size: .small) {
                ScreenColorPicker.pick(onCopy: model.announceCopiedColor)
            }
            DMButton(icon: editing ? "checkmark" : "pencil", label: editing ? "Done" : "Edit", size: .small) {
                editing.toggle()
            }
            Spacer()
            footerButton("power", help: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(m.pt(10))
        .background(Color.dmSidebarBg)
    }

    private func footerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        DMButton(icon: systemImage, label: help, size: .small) {
            NSApp.activate(ignoringOtherApps: true)
            action()
        }
    }
}
