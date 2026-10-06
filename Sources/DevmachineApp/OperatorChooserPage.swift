import SwiftUI
import DevmachineCore

/// Starting the Operator: one card per coding harness on this Mac and a
/// plain terminal, the last pick selected. The pick starts the session and
/// becomes its program.
struct OperatorChooserPage: View {
    let harnesses: [HarnessID]
    var last: SessionLaunchChoice?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.harnessSettingsFacade) private var facade
    @Environment(\.dmMetrics) private var m

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: m.space.xl) {
                VStack(alignment: .leading, spacing: m.space.sm) {
                    Text(verbatim: "Open the Operator session with")
                        .font(.dm(17, weight: .semibold))
                        .foregroundStyle(Color.dmRowText)
                    Text(verbatim: last == nil ? Self.subtitle : Self.laterSubtitle)
                        .font(.dm(12))
                        .foregroundStyle(Color.dmMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: m.pt(200), maximum: m.pt(300)), spacing: m.space.lg)],
                    alignment: .leading, spacing: m.space.lg
                ) {
                    ForEach(options) { option in
                        card(option)
                    }
                }
                HStack(spacing: m.space.xs) {
                    Text(verbatim: "You can change this later in")
                        .font(.dm(11))
                        .foregroundStyle(Color.dmMuted)
                    DMButton("Settings → Harnesses", variant: .link, size: .small) {
                        model.openSettings(.harnesses)
                    }
                }
            }
            .padding(m.space.xxl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dmContentBg)
    }

    static let subtitle = "Your workshop for devmachine itself: a session in your configuration folder. "
        + "Pick a coding agent you have on this Mac and it starts by explaining what you can do here."
    static let laterSubtitle = "Your workshop for devmachine itself: a session in your configuration folder. "
        + "Your last pick is selected."

    private var options: [HarnessLaunchOption] {
        Self.options(for: harnesses, facade: facade)
    }

    /// The harnesses in the order asked, then the plain terminal last.
    static func options(for harnesses: [HarnessID], facade: HarnessSettingsFacade) -> [HarnessLaunchOption] {
        harnesses.compactMap { id in
            facade.descriptor(for: id).map { HarnessLaunchOption(choice: .harness(id), descriptor: $0) }
        } + [.terminal]
    }

    static func title(for option: HarnessLaunchOption) -> String {
        option.choice == .terminal ? "Terminal only" : option.title
    }

    static func detail(for choice: SessionLaunchChoice, firstPick: Bool) -> String {
        guard case let .harness(id) = choice else { return "A plain shell in the configuration folder." }
        guard firstPick else { return "Starts in the configuration folder." }
        return HarnessPrompt.positional.contains(id)
            ? "Starts by asking: \u{201C}\(HarnessPrompt.operatorIntro)\u{201D}"
            : "Starts in the configuration folder; ask it what you can do here."
    }

    private func card(_ option: HarnessLaunchOption) -> some View {
        DMPictureChoice(
            title: Self.title(for: option), detail: Self.detail(for: option.choice, firstPick: last == nil),
            selected: option.choice == last, pictureHeight: 96,
            action: { model.chooseOperatorProgram(option.choice) }
        ) {
            picture(option)
        }
    }

    @ViewBuilder
    private func picture(_ option: HarnessLaunchOption) -> some View {
        let tint = option.color ?? Color.dmRowText
        ZStack {
            tint.opacity(0.14)
            if case let .harness(id) = option.choice,
               let icon = HarnessIconLibrary.bundled.icon(
                   for: id, style: settingsStore.settings?.harnessIconStyle ?? .color) {
                Image(nsImage: icon.image)
                    .renderingMode(icon.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(Color.dmRowText)
                    .frame(width: m.pt(40), height: m.pt(40))
            } else {
                Image(systemName: option.systemImage == "circle.fill" ? "sparkles" : option.systemImage)
                    .font(.dm(28))
                    .foregroundStyle(tint)
            }
        }
    }
}
