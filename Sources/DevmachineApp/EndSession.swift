import AppKit
import SwiftUI
import DevmachineCore

/// A session ⌘W or the sidebar offers to end: what the dialog names and where it runs.
struct SessionEndRequest: Equatable {
    let item: SidebarItem
    let name: String
    let place: String
}

enum CloseCommandRoute: Equatable {
    case askToEndSession
    case closePreview(UUID)
    case closeWindow
}

extension AppModel {
    /// The one session on screen, and only that: a grid, a page, several
    /// selected sessions or the Operator shell leave ⌘W as a window close.
    var endableSession: SidebarItem? {
        guard activePage == nil, let selection, selectedSessions.count <= 1 else { return nil }
        if case let .localSession(handle, _) = selection, handle == Workspace.operatorSession { return nil }
        return selection
    }

    /// A preview with the keyboard is what ⌘W closes, the way a browser
    /// closes its tab; the session beside it stays.
    func handleCloseCommand(inMainWindow: Bool, focusedPreview: UUID? = nil) -> CloseCommandRoute {
        if inMainWindow, let focusedPreview { return .closePreview(focusedPreview) }
        guard inMainWindow, requestEndSession() else { return .closeWindow }
        return .askToEndSession
    }

    @discardableResult
    func requestEndSession() -> Bool {
        guard let item = endableSession else { return false }
        askToEndSession(item)
        return true
    }

    /// The Operator session is not removable, so it is never asked about.
    func askToEndSession(_ item: SidebarItem) {
        if case let .localSession(handle, _) = item, handle == Workspace.operatorSession { return }
        pendingEndSession = SessionEndRequest(item: item, name: endName(item), place: endPlace(item))
    }

    func confirmEndSession() {
        guard let request = pendingEndSession else { return }
        pendingEndSession = nil
        switch request.item {
        case let .session(alias, name): deleteSession(alias: alias, name: name)
        case let .localSession(handle, _): removeLocalSession(handle: handle)
        }
    }

    func cancelEndSession() {
        pendingEndSession = nil
    }

    private func endName(_ item: SidebarItem) -> String {
        switch item {
        case let .session(alias, name): return displayName(for: SessionRef(alias: alias, name: name))
        case let .localSession(handle, _):
            return displayName(for: SessionRef(alias: Workspace.local.alias, name: handle))
        }
    }

    private func endPlace(_ item: SidebarItem) -> String {
        switch item {
        case let .session(alias, _): return workspaces.first { $0.alias == alias }?.name ?? alias
        case .localSession: return "This Mac"
        }
    }
}

/// ⌘W acts on the main window only; Files and every other window keep their
/// own close.
@MainActor
enum CloseCommand {
    static func perform(model: AppModel) {
        let window = NSApp.keyWindow
        let inMainWindow = window?.title == "Devmachine" && window?.sheetParent == nil
        switch model.handleCloseCommand(inMainWindow: inMainWindow, focusedPreview: FocusedPreview.tabID()) {
        case .closeWindow: window?.performClose(nil)
        case let .closePreview(id): PreviewStore.shared.close(id)
        case .askToEndSession: break
        }
    }
}

/// Ending a session cannot be undone, so Return and Escape both cancel and
/// ending takes a click or ⌘⌫, as macOS does when the default would destroy.
struct EndSessionSheet: View {
    @Environment(\.dmMetrics) private var m
    let request: SessionEndRequest
    let onEnd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: m.space.lg) {
            Text(verbatim: "End \(request.name)?")
                .font(.headline)
            Text(verbatim: "The session and anything running in it will stop on \(request.place).")
                .font(.dm(12))
                .foregroundStyle(Color.dmMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                DMButton("Cancel", variant: .outline, action: onCancel)
                    .keyboardShortcut(.defaultAction)
                DMButton("End session", variant: .danger, role: .destructive, action: onEnd)
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .padding(m.pt(20))
        .frame(width: m.pt(380))
        .onExitCommand(perform: onCancel)
    }
}
