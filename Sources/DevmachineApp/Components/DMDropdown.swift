import SwiftUI

/// A labelled choice that opens a list of options under it, drawn with the
/// app's own surfaces instead of the system pop-up button.
struct DMDropdown<Value: Hashable>: View {
    struct Option: Hashable {
        let value: Value
        let title: String
    }

    let label: String
    let options: [Option]
    @Binding var selection: Value
    @Environment(\.dmMetrics) private var m
    @State private var open = false
    @State private var hovering = false

    private var current: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: m.space.sm) {
                if !label.isEmpty {
                    Text(verbatim: label)
                        .foregroundStyle(Color.dmMuted)
                }
                Text(verbatim: current)
                    .foregroundStyle(Color.dmRowText)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.dm(9, weight: .semibold))
                    .foregroundStyle(Color.dmMuted)
            }
            .font(.dm(12))
            .padding(.horizontal, m.row.horizontal)
            .padding(.vertical, m.space.sm)
            .dmSurface(hovering || open ? Color.dmActive : Color.dmSelection, radius: DMRadius.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options, id: \.self) { option in
                    DMDropdownRow(title: option.title, selected: option.value == selection) {
                        selection = option.value
                        open = false
                    }
                }
            }
            .padding(m.space.xs)
            .frame(minWidth: m.pt(180), alignment: .leading)
            .environment(\.colorScheme, .dark)
        }
    }
}

private struct DMDropdownRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.dmMetrics) private var m
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: m.space.sm) {
                Image(systemName: "checkmark")
                    .font(.dm(10, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                Text(verbatim: title)
                    .font(.dm(12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.dmRowText)
            .padding(.horizontal, m.space.md)
            .padding(.vertical, m.space.sm)
            .background(hovering ? Color.dmActive : .clear, in: RoundedRectangle(cornerRadius: m.radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
