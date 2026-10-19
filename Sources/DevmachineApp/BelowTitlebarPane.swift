import SwiftUI

/// A pane whose background runs up under the see-through title bar while its
/// content starts below it. The toolbar band takes every click across the
/// window's top, even where it draws nothing, so text under it cannot be
/// selected: a click there drags the window instead.
struct BelowTitlebarPane<Background: View, Content: View>: View {
    @ViewBuilder var background: Background
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            background.ignoresSafeArea(edges: .top)
            content
        }
    }
}
