import Foundation
@testable import DevmachineApp

/// Stands in for highlight.js in tests: the text back as it is, at once.
struct PlainHighlighter: FileHighlighter {
    func attributedText(_ text: String, language: String) async throws -> AttributedString {
        AttributedString(text)
    }
}
