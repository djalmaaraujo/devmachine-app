import Foundation
import DevmachineCore

/// One tab in the strip over the terminal: a session opened this run, or a
/// file looked at from one. A file tab is a way back to that file in that
/// session; it stays until its own × is pressed, even when the viewer
/// beside the terminal is closed.
enum CenterTab: Hashable {
    case session(SidebarItem)
    case file(owner: SidebarItem, path: String)
    case schema(owner: SidebarItem, folder: String?)

    var owner: SidebarItem {
        switch self {
        case let .session(item): return item
        case let .file(owner, _), let .schema(owner, _): return owner
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
        if let schemaOnScreen { return schemaOnScreen }
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
        case let .schema(owner, folder):
            guard let folder, !folder.isEmpty else { return "Schema · " + title(for: .session(owner)) }
            return "Schema · " + (folder as NSString).lastPathComponent
        }
    }

    var schemaOnScreen: CenterTab? {
        guard activePage == nil, let shownSchema, shownSchema.owner == selection else { return nil }
        return shownSchema
    }

    func openSchema(owner: SidebarItem? = nil, folder: String? = nil) {
        guard let owner = owner ?? selection else { return }
        let tab = CenterTab.schema(owner: owner, folder: folder)
        if selection != owner { selection = owner }
        activePage = nil
        appMode = .code
        openTabs.open(tab)
        shownSchema = tab
    }

    /// The session tab of what is on screen; a file tab as well while the
    /// viewer shows that file beside that session.
    func isSelected(tab: CenterTab) -> Bool {
        guard activePage == nil, selection == tab.owner else { return false }
        switch tab {
        case .session:
            return shownSchema == nil
        case let .file(_, path):
            return shownSchema == nil && fileViewer?.isOpen == true && fileViewer?.path == path
        case .schema:
            return shownSchema == tab
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

    func select(tab: CenterTab) {
        if selection != tab.owner || activePage != nil {
            selection = tab.owner
        } else if appMode != .code {
            appMode = .code
        }
        if case .schema = tab {
            shownSchema = tab
            return
        }
        shownSchema = nil
        guard case let .file(owner, path) = tab else { return }
        guard fileViewer?.isOpen != true || fileViewer?.path != path, let target = commandTarget(for: owner) else { return }
        fileViewer?.open(target, path: path)
    }

    /// Takes the tab off the strip. A session keeps running; a file tab
    /// also closes the viewer when it shows that file. Closing the session
    /// on screen moves to the neighbour tab in the same workspace, or Home
    /// when it was the workspace's last.
    func close(tab: CenterTab) {
        switch tab {
        case .schema:
            openTabs.close(tab, selected: nil)
            if shownSchema == tab { shownSchema = nil }
        case let .file(_, path):
            openTabs.close(tab, selected: nil)
            if fileViewer?.isOpen == true, fileViewer?.path == path { fileViewer?.close() }
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

    func dropTabs(of item: SidebarItem) {
        openTabs.removeAll { $0.owner == item }
        if shownSchema?.owner == item { shownSchema = nil }
    }

    func moveTabs(from old: SidebarItem, to new: SidebarItem) {
        for tab in openTabs.items where tab.owner == old {
            switch tab {
            case .session:
                openTabs.replace(tab, with: .session(new))
            case let .file(_, path):
                openTabs.replace(tab, with: .file(owner: new, path: path))
            case let .schema(_, folder):
                let moved = CenterTab.schema(owner: new, folder: folder)
                openTabs.replace(tab, with: moved)
                if shownSchema == tab { shownSchema = moved }
            }
        }
    }
}
