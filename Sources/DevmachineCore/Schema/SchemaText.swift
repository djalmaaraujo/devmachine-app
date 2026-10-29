import Foundation

enum SchemaText {
    static func stripComments(_ text: String, dashes: Bool = false, slashes: Bool = false, hash: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        let chars = Array(text)
        var index = 0
        var quote: Character?
        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if let open = quote {
                out.append(char)
                if char == "\\", open != "'" || dashes == false, let next {
                    out.append(next)
                    index += 2
                    continue
                }
                if char == open { quote = nil }
                index += 1
                continue
            }
            if char == "'" || char == "\"" || char == "`" {
                quote = char
                out.append(char)
                index += 1
                continue
            }
            if char == "/", next == "*" {
                index += 2
                while index < chars.count, !(chars[index] == "*" && index + 1 < chars.count && chars[index + 1] == "/") {
                    if chars[index] == "\n" { out.append("\n") }
                    index += 1
                }
                index += 2
                continue
            }
            let lineComment = (dashes && char == "-" && next == "-")
                || (slashes && char == "/" && next == "/")
                || (hash && char == "#")
            if lineComment {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            out.append(char)
            index += 1
        }
        return out
    }

    static func splitTopLevel(_ text: String, on separator: Character = ",") -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for char in text {
            if let open = quote {
                current.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == open {
                    quote = nil
                }
                continue
            }
            switch char {
            case "'", "\"", "`":
                quote = char
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth = max(0, depth - 1)
            default:
                break
            }
            if char == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func balanced(_ chars: [Character], from openIndex: Int) -> (inner: String, end: Int)? {
        guard openIndex < chars.count else { return nil }
        let open = chars[openIndex]
        let close: Character
        switch open {
        case "(": close = ")"
        case "[": close = "]"
        case "{": close = "}"
        default: return nil
        }
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = openIndex
        while index < chars.count {
            let char = chars[index]
            if let q = quote {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == q { quote = nil }
            } else if char == "'" || char == "\"" || char == "`" {
                quote = char
            } else if char == open {
                depth += 1
            } else if char == close {
                depth -= 1
                if depth == 0 {
                    return (String(chars[(openIndex + 1)..<index]), index + 1)
                }
            }
            index += 1
        }
        return nil
    }

    static func unquote(_ identifier: String) -> String {
        var value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, let first = value.first, let last = value.last else { return value }
        if (first == "\"" && last == "\"") || (first == "`" && last == "`") || (first == "[" && last == "]")
            || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    static func nameList(_ text: String) -> [String] {
        var inner = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = inner.first, first == "[" || first == "(" { inner.removeFirst() }
        if let last = inner.last, last == "]" || last == ")" { inner.removeLast() }
        return splitTopLevel(inner).map { item in
            let head = item.split(whereSeparator: { $0 == "(" || $0 == " " }).first.map(String.init) ?? item
            return unquote(head)
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
