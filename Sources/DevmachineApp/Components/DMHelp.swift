import SwiftUI

private struct DMShowsHelpKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Off in the quick chat panel. SwiftUI's tooltip bridge crashed the app
    /// there: AppKit asked it for a tooltip while the panel resized under a
    /// streaming answer, and it read a view that was already gone. A window
    /// with no `.help` at all never gets that bridge.
    var dmShowsHelp: Bool {
        get { self[DMShowsHelpKey.self] }
        set { self[DMShowsHelpKey.self] = newValue }
    }
}

private struct DMHelp: ViewModifier {
    let text: String
    @Environment(\.dmShowsHelp) private var showsHelp

    func body(content: Content) -> some View {
        if showsHelp {
            content.help(text)
        } else {
            content
        }
    }
}

extension View {
    /// `.help`, unless the window turned tooltips off with `dmShowsHelp`.
    func dmHelp(_ text: String) -> some View {
        modifier(DMHelp(text: text))
    }
}
