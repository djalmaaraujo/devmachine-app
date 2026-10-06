import DevmachineCore
enum AppPage: Hashable {
    case setup
    case stats
    case subdomains
    case stack([SessionRef])
    /// The Add machine wizard.
    case addMachine
    /// Starting the Operator: which installed harness to run, `last` selected.
    case operatorChooser([HarnessID], last: SessionLaunchChoice?)
}
