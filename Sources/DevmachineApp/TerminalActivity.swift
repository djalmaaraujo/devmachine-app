import Foundation
import os

/// When a remote terminal last printed something, per workspace alias. A
/// mosh session survives a sleep and redraws as soon as it reaches its
/// machine again, so a terminal that just spoke proves the machine answers
/// even when a sweep's fresh login does not get through yet.
final class TerminalActivity: Sendable {
    static let shared = TerminalActivity()

    private let heard = OSAllocatedUnfairLock(initialState: [String: Date]())

    /// Called from the terminal's reading thread for every chunk of output.
    func record(alias: String, at date: Date = Date()) {
        heard.withLock { $0[alias] = date }
    }

    func lastOutput(alias: String) -> Date? {
        heard.withLock { $0[alias] }
    }
}
