import SwiftUI
import AppKit

/// A 6pt drag column between two panes. Paints nothing: the panes' own
/// backgrounds meet, with no hairline in between.
///
/// The drag is measured in window coordinates. Measured in the handle's own,
/// every step moved the handle and with it the origin of the next step, so
/// the pane chased the pointer and shook.
struct ResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    var onDoubleClick: (() -> Void)? = nil

    static let width: CGFloat = 6

    var body: some View {
        Color.clear
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onTapGesture(count: 2) { onDoubleClick?() }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onEnd() }
            )
    }
}
