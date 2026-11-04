import Foundation

/// A run of consecutive lines of a file, numbered from 1, shown as one piece
/// so a long file is laid out piece by piece instead of all at once.
public struct LineChunk: Equatable, Sendable, Identifiable {
    public let firstLine: Int
    public let lines: [String]

    public init(firstLine: Int, lines: [String]) {
        self.firstLine = firstLine
        self.lines = lines
    }

    public var id: Int { firstLine }
    public var lastLine: Int { firstLine + lines.count - 1 }
    public var text: String { lines.joined(separator: "\n") }
}

/// Cuts a file into pieces a lazy stack can lay out one at a time. SwiftUI
/// lays out everything inside a plain stack before the first frame, and a
/// `Text` of 200 KB takes seconds on its own, so nothing on screen may hold
/// the whole file.
public enum FileChunks {
    public static let linesPerChunk = 200
    /// A markdown piece ends at the first blank line past this many bytes.
    public static let markdownTargetBytes = 4_000

    /// The file's lines in pieces of `perChunk`. A trailing newline ends the
    /// last line; it does not start an empty one. An empty file is one empty
    /// line, so the viewer still shows line 1.
    public static func lines(_ text: String, perChunk: Int = linesPerChunk) -> [LineChunk] {
        let all = Self.lines(of: text)
        let size = max(1, perChunk)
        return stride(from: 0, to: all.count, by: size).map { start in
            LineChunk(firstLine: start + 1, lines: Array(all[start..<min(start + size, all.count)]))
        }
    }

    /// The length in characters of the longest line, for a width that does
    /// not change as pieces come on screen.
    public static func longestLine(_ text: String) -> Int {
        lines(of: text).map { $0.count }.max() ?? 0
    }

    /// Markdown in pieces that each parse on their own: a cut happens only at
    /// a blank line outside a fenced code block, once a piece has reached
    /// `targetBytes`. Reference link definitions are repeated in every
    /// piece, so a link keeps resolving after the cut. A document under the
    /// target comes back whole, byte for byte.
    public static func markdown(_ text: String, targetBytes: Int = markdownTargetBytes) -> [String] {
        guard text.utf8.count > targetBytes else { return [text] }
        let all = lines(of: text)
        let definitions = all.filter { isReferenceDefinition($0) }
        var pieces: [[String]] = []
        var current: [String] = []
        var currentBytes = 0
        var fence: (character: Character, length: Int)?

        for line in all {
            if let open = fence {
                if closesFence(line, open) { fence = nil }
            } else if let opened = opensFence(line) {
                fence = opened
            } else if currentBytes >= targetBytes, line.allSatisfy(\.isWhitespace) {
                pieces.append(current)
                current = []
                currentBytes = 0
                continue
            }
            current.append(line)
            currentBytes += line.utf8.count + 1
        }
        if !current.isEmpty { pieces.append(current) }

        return pieces.enumerated().map { index, piece in
            var lines = piece
            let missing = definitions.filter { !piece.contains($0) }
            if !missing.isEmpty {
                lines.append("")
                lines.append(contentsOf: missing)
            }
            return lines.joined(separator: "\n") + (index == pieces.count - 1 && text.hasSuffix("\n") ? "\n" : "")
        }
    }

    static func lines(of text: String) -> [String] {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.count > 1, all.last == "" { all.removeLast() }
        return all
    }

    /// Up to three spaces, then three or more backticks or tildes.
    static func opensFence(_ line: String) -> (character: Character, length: Int)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }.count
        guard run >= 3 else { return nil }
        if first == "`", trimmed.dropFirst(run).contains("`") { return nil }
        return (first, run)
    }

    static func closesFence(_ line: String, _ fence: (character: Character, length: Int)) -> Bool {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3 else { return false }
        let run = trimmed.prefix { $0 == fence.character }.count
        return run >= fence.length && trimmed.dropFirst(run).allSatisfy(\.isWhitespace)
    }

    /// `[label]: destination`, with up to three leading spaces.
    static func isReferenceDefinition(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, trimmed.first == "[",
              let close = trimmed.firstIndex(of: "]"), close > trimmed.startIndex,
              trimmed.index(after: close) < trimmed.endIndex, trimmed[trimmed.index(after: close)] == ":"
        else { return false }
        let rest = trimmed[trimmed.index(close, offsetBy: 2)...]
        return rest.contains { !$0.isWhitespace }
    }
}

/// What the viewer lays out for one file: its lines in pieces, and for
/// markdown the document in pieces of its own, so the Source switch has
/// both at hand.
public struct FileLayout: Equatable, Sendable {
    public let lines: [LineChunk]
    public let markdown: [String]
    public let longestLine: Int

    public init(text: String, kind: FilePreviewKind) {
        lines = FileChunks.lines(text)
        markdown = kind == .markdown ? FileChunks.markdown(text) : []
        longestLine = FileChunks.longestLine(text)
    }
}

public enum AttributedLines {
    /// Cuts a highlighted copy of a file into the same pieces as its plain
    /// lines, keyed by each piece's first line. highlight.js drops blank
    /// lines at the end of a file, so those are put back as blank lines; a
    /// copy whose lines otherwise do not match is refused (nil), and the
    /// plain text is the one to show.
    public static func split(_ attributed: AttributedString, into chunks: [LineChunk]) -> [Int: AttributedString]? {
        let characters = attributed.characters
        var starts: [AttributedString.Index] = [characters.startIndex]
        var index = characters.startIndex
        while index < characters.endIndex {
            if characters[index] == "\n" { starts.append(characters.index(after: index)) }
            index = characters.index(after: index)
        }
        if starts.count > 1, starts.last == characters.endIndex { starts.removeLast() }
        let total = chunks.last.map(\.lastLine) ?? 0
        let available = starts.count
        guard available <= total else { return nil }
        let trailing = chunks.flatMap(\.lines).dropFirst(available)
        guard trailing.allSatisfy(\.isEmpty) else { return nil }

        var result: [Int: AttributedString] = [:]
        for chunk in chunks {
            var piece = AttributedString()
            if chunk.firstLine <= available {
                let start = starts[chunk.firstLine - 1]
                var end = chunk.lastLine < available ? starts[chunk.lastLine] : characters.endIndex
                if end > start, characters[characters.index(before: end)] == "\n" { end = characters.index(before: end) }
                piece = AttributedString(attributed[start..<end])
            }
            let missing = chunk.lastLine - max(available, chunk.firstLine - 1)
            if missing > 0 {
                piece.append(AttributedString(String(repeating: "\n", count: chunk.firstLine <= available ? missing : missing - 1)))
            }
            result[chunk.firstLine] = piece
        }
        return result
    }
}
