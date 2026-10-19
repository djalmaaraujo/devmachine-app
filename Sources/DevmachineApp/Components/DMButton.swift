import SwiftUI

/// The app's own button. Primary is the one action a sheet or page is for;
/// outline sits next to it; danger ends or removes something; ghost is for
/// toolbars and quiet inline actions, and ghostDanger is a quiet one that
/// removes something, red only under the pointer; link reads as text.
enum DMButtonVariant: CaseIterable {
    case primary, outline, danger, dangerOutline, ghost, ghostDanger, link
}

enum DMButtonSize: CaseIterable {
    case small, regular, large

    struct Metrics: Equatable {
        let height: CGFloat
        let fontSize: CGFloat
        let iconSize: CGFloat
        let horizontalPadding: CGFloat
        let spacing: CGFloat
        let radius: CGFloat
    }

    private static let regularIconGap: CGFloat = 5

    /// The sizes at 100%. `fontSize` and `iconSize` are `.dm(_:)` sizes, which
    /// scale on their own.
    var metrics: Metrics {
        switch self {
        case .small:
            Metrics(height: DMControlHeight.small, fontSize: 11, iconSize: DMIconSize.xs,
                    horizontalPadding: DMSpace.md, spacing: DMSpace.xs, radius: DMRadius.row)
        case .regular:
            Metrics(height: DMControlHeight.regular, fontSize: 12.5, iconSize: DMIconSize.sm,
                    horizontalPadding: DMSpace.lg, spacing: Self.regularIconGap, radius: DMRadius.control)
        case .large:
            Metrics(height: DMControlHeight.large, fontSize: 14, iconSize: DMIconSize.md,
                    horizontalPadding: DMSpace.xl, spacing: DMSpace.sm, radius: DMRadius.tile)
        }
    }

    /// The box sizes at `m`; the font sizes stay as they are for `.dm(_:)`.
    func metrics(in m: DMMetrics) -> Metrics {
        let base = metrics
        return Metrics(
            height: m.pt(base.height), fontSize: base.fontSize, iconSize: base.iconSize,
            horizontalPadding: m.pt(base.horizontalPadding), spacing: m.pt(base.spacing),
            radius: m.pt(base.radius))
    }
}

enum DMButtonPalette {
    static let danger = Color(hex: 0xD2463E)
    static let dangerText = Color(hex: 0xFF7B72)
    static let outlineStroke = Color.white.opacity(0.28)
    static let outlineFill = Color.white.opacity(0.08)
    static let outlineHoverFill = Color.white.opacity(0.14)
    static let pressedOpacity = 0.75
    static let disabledOpacity = 0.4
}

/// The colours one variant takes in one state, kept apart from the view so
/// the rules can be tested without rendering.
struct DMButtonAppearance {
    let fill: Color
    let highlight: Color
    let stroke: Color?
    let foreground: Color
    let opacity: Double
    let underline: Bool
    let isBare: Bool

    init(variant: DMButtonVariant, isEnabled: Bool, isPressed: Bool, isHovered: Bool) {
        let hovered = isEnabled && isHovered
        let pressed = isEnabled && isPressed
        var fill = Color.clear
        var stroke: Color?
        var foreground = Color.dmRowText
        var highlight = Color.clear
        switch variant {
        case .primary:
            fill = .accentColor
            foreground = .white
            highlight = hovered ? Color.white.opacity(0.1) : .clear
        case .danger:
            fill = DMButtonPalette.danger
            foreground = .white
            highlight = hovered ? Color.white.opacity(0.1) : .clear
        case .outline:
            fill = hovered ? DMButtonPalette.outlineHoverFill : DMButtonPalette.outlineFill
            stroke = DMButtonPalette.outlineStroke
            foreground = .white
        case .dangerOutline:
            fill = hovered ? DMButtonPalette.danger.opacity(0.12) : .clear
            stroke = DMButtonPalette.danger.opacity(0.7)
            foreground = DMButtonPalette.dangerText
        case .ghost:
            fill = hovered ? .dmSelection : .clear
        case .ghostDanger:
            fill = hovered ? DMButtonPalette.danger.opacity(0.14) : .clear
            foreground = hovered ? DMButtonPalette.dangerText : .dmMuted
        case .link:
            foreground = .accentColor
        }
        self.fill = fill
        self.highlight = highlight
        self.stroke = stroke
        self.foreground = foreground
        self.isBare = variant == .link
        self.underline = variant == .link && hovered
        if !isEnabled {
            opacity = DMButtonPalette.disabledOpacity
        } else {
            opacity = pressed ? DMButtonPalette.pressedOpacity : 1
        }
    }
}

struct DMButtonStyle: ButtonStyle {
    var variant: DMButtonVariant = .primary
    var size: DMButtonSize = .regular
    var isLoading = false
    var fillsWidth = false
    var iconOnly = false
    /// Draws a pointer or focus state without one, for the component gallery.
    var simulated: Simulated?

    enum Simulated { case hovered, pressed, focused }

    static func isInteractive(isEnabled: Bool, isLoading: Bool) -> Bool {
        isEnabled && !isLoading
    }

    func makeBody(configuration: Configuration) -> some View {
        DMButtonBody(style: self, configuration: configuration)
    }
}

private struct DMButtonBody: View {
    let style: DMButtonStyle
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dmMetrics) private var m
    @State private var hovering = false

    var body: some View {
        let metrics = style.size.metrics(in: m)
        let look = DMButtonAppearance(
            variant: style.variant,
            isEnabled: isEnabled || style.isLoading,
            isPressed: configuration.isPressed || style.simulated == .pressed,
            isHovered: (hovering || style.simulated == .hovered) && !style.isLoading)
        let shape = RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)

        configuration.label
            .labelStyle(DMButtonLabelStyle(spacing: metrics.spacing, iconSize: metrics.iconSize))
            .font(.dm(metrics.fontSize, weight: style.variant == .link ? .regular : .medium))
            .lineLimit(1)
            .fixedSize(horizontal: !style.fillsWidth, vertical: false)
            .underline(look.underline)
            .foregroundStyle(look.foreground)
            .opacity(style.isLoading ? 0 : 1)
            .overlay {
                if style.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(metrics.height / DMControlHeight.large)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, look.isBare || style.iconOnly ? 0 : metrics.horizontalPadding)
            .frame(width: style.iconOnly ? metrics.height : nil, height: look.isBare ? nil : metrics.height)
            .frame(maxWidth: style.fillsWidth ? .infinity : nil)
            .background {
                if !look.isBare {
                    shape.fill(look.fill)
                    shape.fill(look.highlight)
                }
            }
            .overlay {
                if let stroke = look.stroke {
                    shape.strokeBorder(stroke, lineWidth: 1)
                }
            }
            .overlay {
                if isFocused || style.simulated == .focused {
                    shape.inset(by: -m.pt(2.5)).strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                }
            }
            .contentShape(shape)
            .opacity(look.opacity)
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { hovering = inside }
            }
    }
}

private struct DMButtonLabelStyle: LabelStyle {
    let spacing: CGFloat
    let iconSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
                .font(.dm(iconSize, weight: .semibold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == DMButtonStyle {
    static func dm(
        _ variant: DMButtonVariant = .primary, size: DMButtonSize = .regular,
        isLoading: Bool = false, fillsWidth: Bool = false
    ) -> DMButtonStyle {
        DMButtonStyle(variant: variant, size: size, isLoading: isLoading, fillsWidth: fillsWidth)
    }
}

/// A `Button` with the app's style. An icon-only one takes its accessibility
/// label as a required argument, so VoiceOver never reads a bare symbol.
struct DMButton: View {
    let title: String?
    let systemImage: String?
    let accessibilityText: String
    let role: ButtonRole?
    let style: DMButtonStyle
    let action: () -> Void

    var isIconOnly: Bool { title == nil }

    init(
        _ title: String, systemImage: String? = nil, variant: DMButtonVariant = .primary,
        size: DMButtonSize = .regular, role: ButtonRole? = nil, isLoading: Bool = false,
        fillsWidth: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityText = title
        self.role = role
        self.style = DMButtonStyle(
            variant: variant, size: size, isLoading: isLoading, fillsWidth: fillsWidth)
        self.action = action
    }

    init(
        icon systemImage: String, label: String, variant: DMButtonVariant = .ghost,
        size: DMButtonSize = .regular, isLoading: Bool = false, action: @escaping () -> Void
    ) {
        self.title = nil
        self.systemImage = systemImage
        self.accessibilityText = label
        self.role = nil
        self.style = DMButtonStyle(
            variant: variant, size: size, isLoading: isLoading, iconOnly: true)
        self.action = action
    }

    var body: some View {
        if isIconOnly {
            button.dmHelp(accessibilityText)
        } else {
            button
        }
    }

    private var button: some View {
        Button(role: role, action: action) {
            if let title, let systemImage {
                Label {
                    Text(verbatim: title)
                } icon: {
                    Image(systemName: systemImage)
                }
            } else if let title {
                Text(verbatim: title)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.dm(style.size.metrics.iconSize + 1.5, weight: .medium))
            }
        }
        .buttonStyle(style)
        .disabled(style.isLoading)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityValue(Text(verbatim: style.isLoading ? "In progress" : ""))
    }
}
