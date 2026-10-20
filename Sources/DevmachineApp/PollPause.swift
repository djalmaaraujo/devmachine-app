import Foundation

/// One workspace held back from every automatic login after ssh failed for
/// it. A refused login pauses that workspace alone: fail2ban counts failed
/// logins per machine and source IP, so asking again soon is what bans this
/// Mac, while another account's working login adds nothing. A second
/// workspace refused on the same machine inside the first one's pause pauses
/// the whole machine, so a locked agent costs at most two refused logins per
/// machine per pause. An unreachable machine pauses its own workspaces, since
/// none of them can answer.
struct PollPause: Equatable {
    enum Reason: Equatable {
        case loginRefused
        case unreachable
        case machineLoginsRefused
        /// A machine that did not answer right after a wake or a network
        /// change, or while an open terminal to it still talks: most likely
        /// the network is still coming up, so it is grey, not red, and asked
        /// again sooner.
        case reconnecting

        /// Paused for the whole machine, so the sidebar shows one card for it.
        var coversMachine: Bool { self != .loginRefused }
    }

    /// A locked agent after waking refuses every login until someone unlocks
    /// it, and each refusal counts toward a ban: 5 minutes keeps a sweep from
    /// stacking them. A host that does not answer costs nothing to ask, so it
    /// is asked again sooner.
    static let loginRefusedSeconds: TimeInterval = 300
    static let unreachableSeconds: TimeInterval = 60
    /// Not shorter: an older CLI counts a login waiting for the agent as
    /// unreachable after 30 seconds, and each of those is a dropped login on
    /// the machine.
    static let reconnectingSeconds: TimeInterval = 30
    /// A workspace refused again right after its pause will most likely be
    /// refused the next time too, so each refusal in a row doubles its pause,
    /// up to this.
    static let loginRefusedMaxSeconds: TimeInterval = 1800

    static func loginRefusedSeconds(refusals: Int) -> TimeInterval {
        let doublings = Double(max(refusals, 1) - 1)
        return min(loginRefusedSeconds * pow(2, doublings), loginRefusedMaxSeconds)
    }

    let reason: Reason
    let machine: String?
    let until: Date
    let seconds: TimeInterval

    init(reason: Reason, machine: String?, until: Date, seconds: TimeInterval? = nil) {
        self.reason = reason
        self.machine = machine
        self.until = until
        self.seconds = seconds ?? Self.seconds(for: reason, refusals: 1)
    }

    init(_ reason: Reason, machine: String?, from now: Date, refusals: Int = 1) {
        let seconds = Self.seconds(for: reason, refusals: refusals)
        self.init(reason: reason, machine: machine, until: now.addingTimeInterval(seconds), seconds: seconds)
    }

    private static func seconds(for reason: Reason, refusals: Int) -> TimeInterval {
        switch reason {
        case .unreachable: return unreachableSeconds
        case .reconnecting: return reconnectingSeconds
        case .loginRefused: return loginRefusedSeconds(refusals: refusals)
        case .machineLoginsRefused: return loginRefusedSeconds
        }
    }

    private var minutes: Int { max(Int((seconds / 60).rounded()), 1) }

    func notice(workspace: String) -> String {
        switch reason {
        case .loginRefused:
            let target = machine ?? "its machine"
            return "Login refused for \(workspace). Paused checking it for \(minutes) min "
                + "so \(target) doesn't block this Mac's IP."
        case .machineLoginsRefused:
            let target = machine ?? workspace
            return "Logins to several workspaces on \(target) were refused. Paused checking \(target) "
                + "for \(minutes) min so it doesn't block this Mac's IP."
        case .unreachable:
            if let machine { return "Couldn't reach \(machine). Paused checking its workspaces for \(minutes) min." }
            return "Couldn't reach \(workspace). Paused checking it for \(minutes) min."
        case .reconnecting:
            return "Reconnecting to \(machine ?? workspace)…"
        }
    }
}
