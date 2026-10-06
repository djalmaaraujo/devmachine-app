import Foundation

public struct HarnessID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let claude = HarnessID(rawValue: "claude")
    public static let codex = HarnessID(rawValue: "codex")
    public static let pi = HarnessID(rawValue: "pi")
    public static let antigravity = HarnessID(rawValue: "antigravity")
    public static let opencode = HarnessID(rawValue: "opencode")
    public static let kimi = HarnessID(rawValue: "kimi")
    public static let cline = HarnessID(rawValue: "cline")
}

/// How a harness icon is drawn: its `<id>-color.svg` in brand colors when
/// there is one, or always its `<id>.svg` in the row's tint.
public enum HarnessIconStyle: String, Codable, Sendable, CaseIterable {
    case color
    case monochrome

    public var title: String {
        switch self {
        case .color: return "Original colors"
        case .monochrome: return "Monochrome"
        }
    }
}

public enum SessionLaunchChoice: Codable, Hashable, Sendable {
    case terminal
    case harness(HarnessID)
    /// A command typed by hand, run as the session's first line the same way
    /// a harness starts.
    case custom(String)
}
