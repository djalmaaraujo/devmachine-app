import SwiftUI

/// What a panel shows in place of its content: still loading, nothing to
/// show, or a read that failed (with Try again and the exact error).
struct DMStatusView: View {
    enum Kind {
        case loading(String)
        case empty(systemImage: String, text: String)
        case failed(title: String? = nil, message: String, retry: (() -> Void)?)
    }

    let kind: Kind
    /// Pages center the state in all the room they have; a list that sits
    /// under a header keeps it near the top.
    var fillsHeight = true
    @Environment(\.dmMetrics) private var m

    var body: some View {
        content
            .padding(m.space.xxl)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .loading(let text):
            VStack(spacing: m.space.md) {
                ProgressView()
                caption(text)
            }
        case .empty(let systemImage, let text):
            VStack(spacing: m.space.md) {
                Image(systemName: systemImage)
                    .font(.dm(22))
                    .foregroundStyle(.secondary)
                caption(text)
            }
        case .failed(let title, let message, let retry):
            DMErrorStateView(
                state: DMErrorState(title: title ?? "Couldn't load this", message: message),
                retry: retry)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.dm(12))
            .foregroundStyle(.secondary)
    }
}

/// A strip above content that stays usable: a failed action, stale data.
struct DMBanner<Trailing: View>: View {
    let message: String
    var systemImage = "exclamationmark.triangle"
    var tint: Color = .orange
    var lineLimit: Int?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dmMetrics) private var m

    var body: some View {
        HStack(alignment: .top, spacing: m.space.md) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.dm(12))
                .foregroundStyle(Color.dmRowText)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .dmHelp(message)
            Spacer()
            trailing()
        }
        .padding(m.row.horizontal)
        .background(tint.opacity(0.12))
    }
}
