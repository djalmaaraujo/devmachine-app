import SwiftUI

/// The corner card's surface, shared by every job card so they stack as one
/// family.
private struct DMToastChrome: ViewModifier {
    @Environment(\.dmMetrics) private var m

    func body(content: Content) -> some View {
        content
            .padding(m.space.lg)
            .dmGlass(radius: DMRadius.toast)
            .shadow(radius: m.pt(10), y: m.pt(3))
    }
}

extension View {
    func dmToastChrome() -> some View {
        modifier(DMToastChrome())
    }
}

enum DMJobStatus: Equatable {
    case running, success, attention, failed
}

/// One line of a job that runs in steps.
struct DMJobStep: Identifiable, Equatable {
    enum State: Equatable {
        case waiting, running, done, attention, failed, skipped
    }

    let id: String
    let title: String
    let state: State
    var detail: String?
}

/// A job card for work that runs in named steps and ends in a result the
/// person can act on: the background-job card with a step list, a close
/// mark once it is over, and a footer for the result.
struct DMJobCard<Footer: View>: View {
    typealias Status = DMJobStatus

    @Environment(\.dmMetrics) private var m

    let title: String
    let status: Status
    let steps: [DMJobStep]
    var onClose: (() -> Void)?
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: m.pt(10)) {
            HStack(alignment: .firstTextBaseline, spacing: m.space.md) {
                statusIcon
                Text(verbatim: title)
                    .font(.dm(12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: m.space.xs)
                if let onClose, status != .running {
                    DMIconButton(systemImage: "xmark", size: 10, tint: nil, action: onClose)
                        .dmHelp("Dismiss")
                }
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: m.pt(5)) {
                    ForEach(steps) { step in stepRow(step) }
                }
            }
            footer()
        }
        .frame(width: m.card.banner, alignment: .leading)
        .dmToastChrome()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.dm(12))
        case .attention:
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange).font(.dm(12))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.dm(12))
        }
    }

    private func stepRow(_ step: DMJobStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: m.pt(7)) {
            stepIcon(step.state)
                .frame(width: m.pt(12))
            VStack(alignment: .leading, spacing: m.space.xxs) {
                Text(verbatim: step.title)
                    .font(.dm(11.5))
                    .foregroundStyle(step.state == .waiting || step.state == .skipped ? Color.dmMuted : Color.dmRowText)
                if let detail = step.detail {
                    Text(verbatim: detail)
                        .font(.dm(10.5))
                        .foregroundStyle(Color.dmMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: DMJobStep.State) -> some View {
        switch state {
        case .waiting:
            Image(systemName: "circle").foregroundStyle(Color.dmMuted).font(.dm(9))
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .done:
            Image(systemName: "checkmark").foregroundStyle(.green).font(.dm(10, weight: .semibold))
        case .attention:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).font(.dm(10))
        case .failed:
            Image(systemName: "xmark").foregroundStyle(.red).font(.dm(10, weight: .semibold))
        case .skipped:
            Image(systemName: "minus").foregroundStyle(Color.dmMuted).font(.dm(10))
        }
    }
}

extension DMJobCard where Footer == EmptyView {
    init(title: String, status: Status, steps: [DMJobStep], onClose: (() -> Void)? = nil) {
        self.init(title: title, status: status, steps: steps, onClose: onClose) { EmptyView() }
    }
}
