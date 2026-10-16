import Foundation

/// A `devmachine sync` running on this Mac outside the app: typed in a
/// terminal, or run by the Operator while it sets up a new workspace.
public struct LocalSync: Equatable, Sendable {
    public let pid: Int
    /// The `--machine` it names. Nil when it names none, which the CLI
    /// takes as the only machine configured.
    public let machine: String?
    /// Run from inside the Operator session.
    public let byOperator: Bool

    public init(pid: Int, machine: String?, byOperator: Bool) {
        self.pid = pid
        self.machine = machine
        self.byOperator = byOperator
    }

    public func covers(machine other: String) -> Bool {
        machine == nil || machine == other
    }
}

/// Finding the syncs in one `ps` listing, so a workspace waiting for its
/// first sync can say one is on its way instead of asking for one.
public enum LocalSyncs {
    /// Every process with its parent and its whole command line.
    public static let psArguments = ["-axo", "pid=,ppid=,args="]

    /// Global flags that take their value as the next argument.
    private static let valueFlags: Set<String> = ["--config", "--format", "--machine", "--tags"]

    /// `operatorPID` is the Operator session's process, when it runs: a sync
    /// below it in the tree is the Operator's.
    public static func parse(_ output: String, operatorPID: Int? = nil) -> [LocalSync] {
        let entries = ProcessTree.parse(output)
        let parents = Dictionary(entries.map { ($0.pid, $0.parent) }, uniquingKeysWith: { first, _ in first })
        return entries.compactMap { entry in
            guard let machine = syncMachine(entry.command) else { return nil }
            return LocalSync(
                pid: entry.pid, machine: machine,
                byOperator: operatorPID.map { descends(entry.pid, from: $0, parents: parents) } ?? false)
        }
    }

    /// The `--machine` of a `devmachine sync` command line: `.some(nil)` for
    /// a sync that names none, nil for anything that is not a sync.
    static func syncMachine(_ command: String) -> String?? {
        let words = command.split(separator: " ").map(String.init)
        guard let program = words.first, (program as NSString).lastPathComponent == "devmachine" else { return nil }
        var machine: String?
        var subcommand: String?
        var index = 1
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("--machine=") {
                machine = String(word.dropFirst("--machine=".count))
            } else if valueFlags.contains(word) {
                if word == "--machine", index + 1 < words.count { machine = words[index + 1] }
                index += 1
            } else if !word.hasPrefix("-"), subcommand == nil {
                subcommand = word
            }
            index += 1
        }
        guard subcommand == "sync" else { return nil }
        return .some(machine)
    }

    private static func descends(_ pid: Int, from root: Int, parents: [Int: Int]) -> Bool {
        var current = pid
        var seen: Set<Int> = []
        while let parent = parents[current], parent > 1, seen.insert(parent).inserted {
            if parent == root { return true }
            current = parent
        }
        return false
    }
}
