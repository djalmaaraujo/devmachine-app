import Foundation

/// What opening the Operator session does. With coding harnesses on this
/// Mac, every start asks which one to run, the last answer selected. A
/// session that already runs is only shown: a line typed into it would land
/// in whatever program it is running.
public enum OperatorLaunch: Equatable, Sendable {
    case attach
    case choose([HarnessID], last: SessionLaunchChoice?)
    case start(SessionLaunchChoice)

    /// `installed` is every harness whose CLI is on this Mac, turned on in
    /// Settings or not: the chooser is how people find out what they have.
    /// With none installed the terminal opens and nothing is remembered, so
    /// the chooser still shows once a harness is installed.
    public static func plan(
        isRunning: Bool, saved: SessionLaunchChoice?, installed: [HarnessID]
    ) -> OperatorLaunch {
        if isRunning { return .attach }
        return installed.isEmpty ? .start(.terminal) : .choose(installed, last: saved)
    }
}
