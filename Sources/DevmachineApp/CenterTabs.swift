import Foundation
import DevmachineCore

/// One tab in the strip over the terminal: a session opened this run, or a
/// file looked at from one. A file tab shows the file in the terminal's
/// place, the way a session tab shows its terminal; it stays until its own
/// × is pressed, even when the viewer is closed from its own header.
enum CenterTab: Hashable {
    case session(SidebarItem)
    case file(owner: SidebarItem, path: String)

    var owner: SidebarItem {
        switch self {
        case let .session(item): return item
        case let .file(owner, _): return owner
        }
    }

    /// The workspace the tab is shown under; a local session's is Local's.
    var workspaceAlias: String { owner.sessionRef.alias }
}

extension AppModel {
    /// The strip's tabs: those of the workspace of the session on screen.
    /// Home and a page over the session show none; the tabs stay open.
    var visibleTabs: [CenterTab] {
        guard activePage == nil, let selection else { return [] }
        let alias = selection.sessionRef.alias
        return openTabs.items.filter { $0.workspaceAlias == alias }
    }

    /// The tab ⌘W closes: the file the viewer shows beside the session when
    /// it has a tab, else the session's own tab when it is open. Nothing on
    /// Home, a page, the session grid, or a session whose tab was dropped.
    var tabOnScreen: CenterTab? {
        guard activePage == nil, let selection else { return nil }
        if fileViewer?.isOpen == true, let path = fileViewer?.path {
            let fileTab = CenterTab.file(owner: selection, path: path)
            if openTabs.contains(fileTab) { return fileTab }
        }
        let sessionTab = CenterTab.session(selection)
        return openTabs.contains(sessionTab) ? sessionTab : nil
    }

    func title(for tab: CenterTab) -> String {
        switch tab {
        case let .session(.session(_, name)):
            return name
        case let .session(.localSession(handle, _)):
            return localSessions.first { $0.handle == handle }?.name ?? handle
        case let .file(_, path):
            return (path as NSString).lastPathComponent
        }
    }

    /// The one tab on screen: the file the viewer shows in the session's
    /// place, else the session's own tab.
    func isSelected(tab: CenterTab) -> Bool {
        guard activePage == nil, selection == tab.owner else { return false }
        switch tab {
        case .session:
            return fileViewer?.isOpen != true
        case let .file(_, path):
            return fileViewer?.isOpen == true && fileViewer?.path == path
        }
    }

    func harnessBadges(for item: SidebarItem) -> [HarnessBadgePresentation] {
        switch item {
        case let .session(alias, name):
            guard let session = sessions(in: alias).first(where: { $0.name == name }) else { return [] }
            return badges(for: session)
        case let .localSession(handle, _):
            guard let session = localSessions.first(where: { $0.handle == handle }) else { return [] }
            return badges(for: session)
        }
    }

    /// A session tab puts its terminal on screen, in place of a file shown
    /// there; a file tab shows its file in place of the terminal.
    func select(tab: CenterTab) {
        if selection != tab.owner || activePage != nil {
            selection = tab.owner
        } else if appMode != .code {
            appMode = .code
        }
        switch tab {
        case .session:
            fileViewer?.close()
        case let .file(owner, path):
            guard fileViewer?.isOpen != true || fileViewer?.path != path, let target = commandTarget(for: owner) else { return }
            fileViewer?.open(target, path: path)
        }
    }

    /// Takes the tab off the strip. A session keeps running; a file tab
    /// also drops what was read of the file. Closing the tab on screen
    /// moves to the neighbour tab in the same workspace, or Home when it
    /// was the workspace's last.
    func close(tab: CenterTab) {
        switch tab {
        case let .file(owner, path):
            let wasOnScreen = isSelected(tab: tab)
            let next = openTabs.close(tab, selected: wasOnScreen ? tab : nil) { $0.workspaceAlias == tab.workspaceAlias }
            if let target = commandTarget(for: owner) { fileViewer?.forget(target, path: path) }
            guard wasOnScreen else { return }
            if let next {
                select(tab: next)
            } else {
                fileViewer?.close()
            }
        case let .session(item):
            let wasOnScreen = activePage == nil && selection == item
            openTabs.removeAll { $0.owner == item && $0 != tab }
            let next = openTabs.close(tab, selected: wasOnScreen ? tab : nil) { $0.workspaceAlias == tab.workspaceAlias }
            guard wasOnScreen else { return }
            if let next {
                select(tab: next)
            } else {
                goHome()
            }
        }
    }

    func fileOpened(path: String) {
        guard let selection, activePage == nil else { return }
        openTabs.open(.file(owner: selection, path: path))
    }

    /// The file left the screen and the terminal is back in its place. The
    /// pane comes back unchanged, so the program inside is asked to draw
    /// again, as after a page (see `activePage`).
    func fileClosed() {
        guard activePage == nil, let selection else { return }
        TerminalRegistry.shared.requestRepaint(selection.terminalKind)
        TerminalRegistry.shared.requestFocus(selection.terminalKind)
    }

    func dropTabs(of item: SidebarItem) {
        openTabs.removeAll { $0.owner == item }
    }

    func moveTabs(from old: SidebarItem, to new: SidebarItem) {
        for tab in openTabs.items where tab.owner == old {
            switch tab {
            case .session:
                openTabs.replace(tab, with: .session(new))
            case let .file(_, path):
                openTabs.replace(tab, with: .file(owner: new, path: path))
            }
        }
    }
}
