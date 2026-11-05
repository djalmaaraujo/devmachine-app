import Foundation
import HighlightSwift

/// Colours a whole file once, off the main thread. A seam: the viewer's
/// tests hand in a plain one, because highlight.js runs its JavaScript on
/// an actor and holds a cooperative thread for the length of it, which on
/// a three-core CI runner starved the detached read of the next test.
protocol FileHighlighter: Sendable {
    func attributedText(_ text: String, language: String) async throws -> AttributedString
}

/// highlight.js, through HighlightSwift, in the viewer's dark theme. One
/// JavaScript context for the app, asked once per file, never per piece.
struct HighlightJSHighlighter: FileHighlighter {
    private static let highlight = Highlight()

    func attributedText(_ text: String, language: String) async throws -> AttributedString {
        try await Self.highlight.attributedText(text, language: language, colors: .dark(.atomOne))
    }
}
