import SwiftTerm

/// Cuts every line on screen to the terminal's width. SwiftTerm trims a
/// line's cells when the pane gets narrower only in a buffer with
/// scrollback; the alternate screen, where tmux draws, keeps the cells past
/// the new width, nothing draws them, a program's erase-to-end-of-line
/// stops at the width, and a copy reads a line to its last cell. That is
/// how a copy brought text from a wider screen that nobody could see.
enum TerminalLineTrim {
    static func trim(_ terminal: Terminal) {
        let cols = terminal.cols
        let blank = terminal.buffer.getNullCell()
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row), line.count > cols else { continue }
            line.resize(cols: cols, fillData: blank)
        }
    }

    static func trim(_ view: TerminalView) {
        guard let terminal = terminal(behind: view) else { return }
        trim(terminal)
    }

    /// The `Terminal` a view draws. At the pinned SwiftTerm revision the view
    /// keeps it in an internal property with no public way to it, so it is
    /// read by reflection, which sees stored properties whatever their
    /// access level; `TerminalLineTrimTests` checks the property is still
    /// there after a SwiftTerm bump.
    static func terminal(behind view: TerminalView) -> Terminal? {
        var mirror: Mirror? = Mirror(reflecting: view)
        while let current = mirror {
            if let terminal = current.descendant("terminal") as? Terminal { return terminal }
            mirror = current.superclassMirror
        }
        return nil
    }
}
