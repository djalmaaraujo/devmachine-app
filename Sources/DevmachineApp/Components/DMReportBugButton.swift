import AppKit
import DevmachineCore
import SwiftUI

/// Opens GitHub's new-issue page in the browser with the failure filled
/// in, redacted (`BugReport`). The person reads it and submits it there;
/// the app never posts anything.
struct DMReportBugButton: View {
    let report: () -> BugReport

    var body: some View {
        DMButton("Report a bug", systemImage: "ladybug", variant: .ghost, size: .small) {
            guard let url = report().url(context: BugReportEnvironment.context()) else { return }
            NSWorkspace.shared.open(url)
        }
        .dmHelp("Opens a new GitHub issue in your browser, filled in and with personal data taken out. "
            + "Nothing is sent until you submit it there.")
    }
}

/// The versions and the names to take out of a report, read when the button is clicked.
@MainActor
enum BugReportEnvironment {
    /// Addresses and domains the person typed this run, besides the saved ones.
    static var typedHosts: [String] = []
    static var typedDomains: [String] = []
    /// The machine and workspace names typed this run.
    static var typedMachines: [String] = []
    static var typedWorkspaces: [String] = []

    static func context() -> BugReport.Context {
        let settings = AppModel.shared?.settings
        return BugReport.Context(
            home: NSHomeDirectory(), user: NSUserName(),
            hosts: typedHosts + [settings?.publicIP ?? ""] + (MachinesStore.shared.machines.flatMap(\.hosts)),
            domains: typedDomains + [settings?.baseDomain ?? ""],
            machines: typedMachines + MachinesStore.shared.machines.map(\.name),
            workspaces: typedWorkspaces + MachinesStore.shared.machines.flatMap(\.workspaces)
                + (AppModel.shared?.workspaces.map(\.name) ?? []))
    }

    static func report(
        title: String, stepID: String, command: String, exitCode: Int32?, lines: [String]
    ) -> BugReport {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return BugReport(
            title: title,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development build",
            cliVersion: MachinesStore.shared.snapshot?.cliVersion?.description ?? "unknown",
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", arch: LimaInstaller.thisMac,
            stepID: stepID, command: command, exitCode: exitCode, lines: lines)
    }
}
