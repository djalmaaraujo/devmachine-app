import Foundation
import Network

/// Says when the network comes back or moves to other interfaces, from the
/// system's own path updates: nothing is polled. After a wake, Wi-Fi and
/// Tailscale come up a few seconds apart, and each step is one update.
final class NetworkReturnWatch: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.devmachine.network-watch")
    private var last: PathSnapshot?

    func start(_ returned: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let next = PathSnapshot(path)
            let previous = self.last
            self.last = next
            guard let previous, PathSnapshot.returned(from: previous, to: next) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { returned() } }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/// The part of a network path that says whether machines could answer now
/// when they could not before.
struct PathSnapshot: Equatable {
    let satisfied: Bool
    let interfaces: [String]

    init(satisfied: Bool, interfaces: [String]) {
        self.satisfied = satisfied
        self.interfaces = interfaces
    }

    init(_ path: NWPath) {
        self.init(satisfied: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name))
    }

    /// Satisfied again, or satisfied over a different set of interfaces, such
    /// as Tailscale's coming up after Wi-Fi. Losing the network is not a
    /// return: nothing could answer.
    static func returned(from previous: PathSnapshot, to next: PathSnapshot) -> Bool {
        guard next.satisfied else { return false }
        return !previous.satisfied || previous.interfaces != next.interfaces
    }
}
