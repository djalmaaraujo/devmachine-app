import Foundation
import DevmachineCore

private struct CLIDNSProviderList: Decodable {
    let providers: [DNSProviderAnswer]
}

private struct CLIDNSListResult: Decodable {
    let zone: String
    let provider: String
    let records: [DNSRecordRow]
}

struct CLIWorkspace: Codable, Equatable, Sendable {
    let name: String
    let machine: String
    let user: String
    let packages: [String]
}

private struct CLIWorkspaceList: Decodable {
    let workspaces: [CLIWorkspace]
}

/// `workspaces list`'s rows with their `settings`, which the cached
/// `CLIWorkspace` leaves out.
private struct CLIWorkspaceDetailList: Decodable {
    struct Row: Decodable {
        let name: String
        let machine: String
        let user: String
        let packages: [String]?
        let settings: [String: SettingValue]?
        let credentials: [String: String]?
    }

    let workspaces: [Row]
}

struct CLIConfigPath: Decodable, Equatable, Sendable {
    let path: String
    let source: String
}

/// One entry of `config show`'s `machines` list. `hosts` is every address the
/// CLI would try in order (tailnet first, then a public fallback) — the app
/// only needs one to show, so it picks the first that is not a tailnet
/// address (`100.64.0.0/10`).
struct CLIConfigMachine: Decodable, Equatable, Sendable {
    let name: String
    let hosts: [String]
    let adminUser: String
    let port: Int
    let workspaces: [String]
    let isSelf: Bool
    /// The machine's own packages from `config.yml` (CLI 0.7.27+); nil from
    /// an older CLI, which leaves the field out.
    var packages: [String]?
    /// Where the machine is (CLI 0.7.30+); nil from an older CLI.
    var location: String?
    /// `linux` or `macos`, as a command last read it; nil from an older CLI
    /// or for a machine nothing has read yet.
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case name, hosts, workspaces, port, packages, location, platform
        case adminUser = "admin_user"
        case isSelf = "self"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        adminUser = try c.decodeIfPresent(String.self, forKey: .adminUser) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        workspaces = try c.decodeIfPresent([String].self, forKey: .workspaces) ?? []
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        packages = try c.decodeIfPresent([String].self, forKey: .packages)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
    }
}

struct CLIConfigWorkspace: Decodable, Equatable, Sendable {
    let name: String
    let machine: String
    let user: String
}

struct CLIConfigShow: Decodable, Equatable, Sendable {
    let machines: [CLIConfigMachine]
    let workspaces: [CLIConfigWorkspace]
    let domain: String
    /// `defaults.workspace` and the top-level login answers, CLI 0.7.29+;
    /// nil from an older CLI, which leaves them out.
    var defaultWorkspacePackages: [String]?
    var credentials: [String: String]?

    private struct Defaults: Decodable {
        let workspace: [String]?
    }

    enum CodingKeys: String, CodingKey {
        case machines, workspaces, domain, defaults, credentials
    }

    init(machines: [CLIConfigMachine], workspaces: [CLIConfigWorkspace], domain: String) {
        self.machines = machines
        self.workspaces = workspaces
        self.domain = domain
    }

    /// The CLI leaves out `domain` and `workspaces` when none is set.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machines = try c.decodeIfPresent([CLIConfigMachine].self, forKey: .machines) ?? []
        workspaces = try c.decodeIfPresent([CLIConfigWorkspace].self, forKey: .workspaces) ?? []
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        defaultWorkspacePackages = try c.decodeIfPresent(Defaults.self, forKey: .defaults)?.workspace
        credentials = try c.decodeIfPresent([String: String].self, forKey: .credentials)
    }
}

/// One entry of `devmachine --format json aliases` — the exact ssh host
/// name for a workspace, as the CLI itself wrote it, instead of the app
/// guessing at a `<workspace>-<suffix>` pattern.
struct CLIAlias: Decodable, Equatable, Sendable {
    let name: String
    let host: String
    let user: String
    let port: Int
}

private struct CLIAliasList: Decodable {
    let aliases: [CLIAlias]
}

/// `aliases` plus whether the CLI writes them into the SSH configuration.
/// With `sshAliases` false nothing was ever written, so `ssh <alias>` has no
/// Host entry to find.
struct CLIAliasListing: Decodable, Equatable, Sendable {
    let aliases: [CLIAlias]
    let sshAliases: Bool?

    enum CodingKeys: String, CodingKey {
        case aliases
        case sshAliases = "ssh_aliases"
    }
}

/// Every failed call into the `devmachine-app` package is announced here, so
/// the machine readiness check hears about a missing or old package from
/// whichever feature met it first.
enum PackageCallReports {
    static let notification = Notification.Name("DevmachinePackageCallFailed")

    struct Report: Equatable, Sendable {
        let machine: String?
        let workspace: String?
        let detail: String
    }

    static func post(machine: String? = nil, workspace: String? = nil, detail: String) {
        var info: [String: String] = ["detail": detail]
        info["machine"] = machine
        info["workspace"] = workspace
        NotificationCenter.default.post(name: notification, object: nil, userInfo: info)
    }

    static func report(from notification: Notification) -> Report? {
        guard let info = notification.userInfo as? [String: String], let detail = info["detail"] else { return nil }
        return Report(machine: info["machine"], workspace: info["workspace"], detail: detail)
    }
}

/// One entry of `packages list`: `installedOn` reads like `"machine devmachine"`
/// or `"workspace acme"`.
struct CLIPackage: Codable, Equatable, Sendable {
    let name: String
    let scope: String
    let installedOn: [String]
    var summary: String?
    /// `release` for the pinned package release, `local` for the person's own.
    var source = ""
    /// `kind`, `category` and `credentials` come from CLI 0.7.27 on. A
    /// nil `credentials` means the CLI did not report them at all.
    var kind: String?
    var category: String?
    var credentials: [PackageCredential]?
    /// `platforms` (empty is any) and `needs` come from CLI 0.7.27 on.
    var platforms: [String] = []
    var needs: [String] = []
    /// What `--set` accepts per package, CLI 0.7.29+.
    var variables: [PackageVariable]?

    enum CodingKeys: String, CodingKey {
        case name, scope, summary, source, kind, category, credentials, platforms, needs, variables
        case installedOn = "installed_on"
    }

    init(
        name: String, scope: String, installedOn: [String], summary: String? = nil, source: String = "",
        kind: String? = nil, category: String? = nil, credentials: [PackageCredential]? = nil,
        platforms: [String] = [], needs: [String] = [], variables: [PackageVariable]? = nil
    ) {
        self.variables = variables
        self.name = name
        self.scope = scope
        self.installedOn = installedOn
        self.summary = summary
        self.source = source
        self.kind = kind
        self.category = category
        self.credentials = credentials
        self.platforms = platforms
        self.needs = needs
    }

    /// A package the configuration asks for that no recipe provides comes
    /// back with no scope; one such row must not fail the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        installedOn = try c.decodeIfPresent([String].self, forKey: .installedOn) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        credentials = try c.decodeIfPresent([PackageCredential].self, forKey: .credentials)
        platforms = try c.decodeIfPresent([String].self, forKey: .platforms) ?? []
        needs = try c.decodeIfPresent([String].self, forKey: .needs) ?? []
        variables = try c.decodeIfPresent([PackageVariable].self, forKey: .variables)
    }

    /// The name its token is stored under with `secrets set`.
    var secretName: String {
        DNSProviderCatalog.secretName(package: name, credentials: credentials)
    }

    /// A list from a CLI that reports kinds is read by kind alone; one from
    /// an older CLI by the providers' summary.
    static func dnsProviders(in packages: [CLIPackage]) -> [CLIPackage] {
        let reportsKinds = packages.contains { $0.kind != nil || $0.credentials != nil }
        return packages.filter {
            DNSProviderCatalog.isProvider(kind: $0.kind, summary: $0.summary, listReportsKinds: reportsKinds)
        }
    }

    func isInstalled(onMachine machine: String) -> Bool {
        installedOn.contains("machine \(machine)")
    }

    var info: PackageInfo {
        PackageInfo(
            name: name, scope: scope, summary: summary ?? "", source: source, platforms: platforms, needs: needs,
            category: category ?? "", variables: variables ?? [])
    }

    var entry: PackageEntry {
        PackageEntry(
            name: name, scope: scope, source: source, summary: summary ?? "", category: category,
            platforms: platforms, needs: needs, credentialNames: (credentials ?? []).map(\.name),
            installedOn: installedOn)
    }
}

private struct CLIPackageList: Decodable {
    let packages: [CLIPackage]
}

struct CLIMachine: Codable, Equatable, Sendable {
    let name: String
    let isSelf: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case isSelf = "self"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
    }

    init(name: String, isSelf: Bool) {
        self.name = name
        self.isSelf = isSelf
    }
}

struct ExposureListing: Codable, Equatable, Sendable {
    let sites: [ExposedSite]
    let warning: String?

    /// The CLI's own wording when the machine has no caddy package.
    var caddyIsMissing: Bool { warning?.contains("caddy is not on") ?? false }
}

/// `devmachine sessions --format json`: every requested workspace, with its
/// sessions or the reason they could not be listed.
struct CLISessionList: Decodable, Equatable, Sendable {
    let workspaces: [CLISessionWorkspace]
}

struct CLISessionWorkspace: Decodable, Equatable, Sendable {
    let name: String
    let sessions: [CLISession]
    let error: CLISessionError?
}

struct CLISession: Decodable, Equatable, Sendable {
    let name: String
    let windows: Int
    let path: String
    let branch: String
    let ageSeconds: Int
    let harnesses: [String]
    let busy: Bool
    let attention: Bool

    enum CodingKeys: String, CodingKey {
        case name, windows, path, branch, harnesses, busy, attention
        case ageSeconds = "age_seconds"
    }
}

struct CLISessionError: Decodable, Equatable, Sendable {
    let kind: String
    let message: String
}

enum DevmachineCLIError: LocalizedError, Equatable {
    case commandFailed(String)
    case executableNotFound([String])
    case needsNewerCLI(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.trimmingCharacters(in: .whitespacesAndNewlines)
        case .executableNotFound(let paths):
            return "Devmachine CLI was not found at \(paths.joined(separator: " or ")). Install it with `\(CLIInstallPlan.noHomebrewCommand)`."
        case .needsNewerCLI(let command):
            return "The installed devmachine CLI has no `\(command)` yet. Update it with `devmachine update`."
        }
    }

    /// A package command the installed release does not know yet — the
    /// machine has an older `devmachine-app` than the app expects. The fix is
    /// `devmachine packages pin` then `sync`, not the "add the package" gate.
    var isUnknownPackageCommand: Bool {
        guard case let .commandFailed(detail) = self else { return false }
        return detail.contains("does not accept")
    }
}

struct DevmachineCLI: Sendable {
    let executable: String
    let runner: any CommandRunner
    let customSocket: String?
    let socketFileExists: @Sendable (String) -> Bool
    let processEnvironment: [String: String]

    init(
        executable: String,
        runner: any CommandRunner = ProcessRunner(),
        customSocket: String? = nil,
        socketFileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.runner = runner
        self.customSocket = customSocket
        self.socketFileExists = socketFileExists
        self.processEnvironment = processEnvironment
    }

    /// `DEVMACHINE_CLI` runs another CLI binary than the installed one, the
    /// way the CLI's own `DEVMACHINE_CONFIG` picks another configuration.
    static func overridePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let path = environment["DEVMACHINE_CLI"], !path.isEmpty else { return nil }
        return path
    }

    static func resolve(
        injected: String? = DevmachineCLI.overridePath(),
        runner: any CommandRunner = ProcessRunner(),
        customSocket: String? = RemoteCommands.SSHAgentSocketPreference.shared.current(),
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> DevmachineCLI {
        let paths = [injected].compactMap { $0 } + [
            "/opt/homebrew/bin/devmachine",
            "/usr/local/bin/devmachine",
            CLIInstallPlan.installerBinary(home: NSHomeDirectory()),
        ]
        guard let executable = paths.first(where: exists) else {
            throw DevmachineCLIError.executableNotFound(paths)
        }
        return DevmachineCLI(executable: executable, runner: runner, customSocket: customSocket)
    }

    /// Publishes a workspace's port. The CLI applies the route on Caddy at
    /// once and says how it went in JSON (0.7.21 and newer); the whole output
    /// comes back, because a failed apply still printed what it recorded.
    /// `via` names another machine whose Caddy serves it, for a workspace
    /// on a machine the internet cannot reach.
    func exposeAdd(workspace: String, port: Int, host: String, via: String? = nil) throws -> CLIOutput {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "expose", "add", workspace, String(port), "--host", host]
                + (via.map { ["--via", $0] } ?? [])
                + ["--publish"],
            environment: environment()
        )
        return CLIOutput(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    /// Saves `paths` from the workspace into `directory` on this Mac. The CLI
    /// answers per path, so one missing file does not hide the others.
    /// `progress` gets each running count while the bytes arrive; a CLI too
    /// old to send them still downloads, with no counts.
    func download(
        paths: [String], workspace: String, to directory: String,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) throws -> [DownloadedFile] {
        var result: (stdout: String, stderr: String, exitCode: Int32)
        if let progress {
            result = try runner.runCapturing(
                executable: executable,
                args: FileTransfer.downloadArguments(paths: paths, workspace: workspace, to: directory, progress: true),
                environment: environment(),
                onStderrLine: { line in FileTransfer.parseProgress(line).map(progress) }
            )
            if FileTransfer.isUnknownFlag(result.stderr, FileTransfer.progressFlag) {
                result = try runDownload(paths: paths, workspace: workspace, to: directory)
            }
        } else {
            result = try runDownload(paths: paths, workspace: workspace, to: directory)
        }
        if let files = FileTransfer.parseDownloads(result.stdout) { return files }
        if FileTransfer.isUnknownCommand(result.stderr, FileTransfer.downloadCommand) {
            throw DevmachineCLIError.needsNewerCLI(FileTransfer.downloadCommand)
        }
        result.stderr = FileTransfer.withoutProgress(result.stderr)
        try requireSuccess(result)
        throw DevmachineCLIError.commandFailed("The CLI gave no result for the download.")
    }

    private func runDownload(paths: [String], workspace: String, to directory: String) throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        try runner.runCapturing(
            executable: executable,
            args: FileTransfer.downloadArguments(paths: paths, workspace: workspace, to: directory),
            environment: environment()
        )
    }

    /// Sends `files` into `directory` in the workspace's home.
    func upload(files: [String], workspace: String, directory: String) throws -> [UploadedFile] {
        let result = try runner.runCapturing(
            executable: executable,
            args: FileTransfer.uploadArguments(files: files, workspace: workspace, directory: directory),
            environment: environment()
        )
        if let files = FileTransfer.parseUploads(result.stdout) { return files }
        try requireSuccess(result)
        throw DevmachineCLIError.commandFailed("The CLI gave no result for the upload.")
    }

    /// What `machine`'s Caddy publishes. `expose list` acts on one machine
    /// and refuses to guess with several configured, so the machine is
    /// always named. A machine it cannot ask still exits 0: it prints `null`
    /// and says why on stderr, which is kept as `warning`.
    func listExposures(machine: String) throws -> ExposureListing {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--machine", machine, "--format", "json", "expose", "list"],
            environment: environment()
        )
        try requireSuccess(result)
        let sites = try JSONDecoder().decode([ExposedSite]?.self, from: Data(result.stdout.utf8)) ?? []
        let warning = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExposureListing(sites: sites, warning: warning.isEmpty ? nil : warning)
    }

    /// Stops publishing a site, on Caddy at once when the machine answers.
    /// `--yes` skips the CLI's own confirmation prompt: the app already asked.
    func exposeRemove(host: String, machine: String) throws -> CLIOutput {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--machine", machine, "--format", "json", "expose", "rm", host, "--yes"],
            environment: environment()
        )
        return CLIOutput(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    /// Every DNS provider installed on `machine`, and the zones it can see —
    /// the tab strip only shows a tab for a provider that is here.
    func dnsProviders(machine: String) throws -> [DNSProviderAnswer] {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--machine", machine, "--format", "json", "dns", "providers"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIDNSProviderList.self, from: Data(result.stdout.utf8)).providers
    }

    /// Every record `provider` holds for `zone` on `machine` — read-only,
    /// straight from the registrar.
    func dnsList(machine: String, provider: String, zone: String) throws -> [DNSRecordRow] {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--machine", machine, "--format", "json", "dns", "list", zone, "--dns-provider", provider],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIDNSListResult.self, from: Data(result.stdout.utf8)).records
    }

    /// Asks for `package` on `machine` in the configuration on this Mac.
    /// Nothing reaches the machine until a sync.
    func addPackage(_ package: String, machine: String) throws {
        let result = try runner.runCapturing(
            executable: executable,
            args: DNSProviderSetup.addArguments(package: package, machine: machine),
            environment: environment()
        )
        try requireSuccess(result)
    }

    /// Writes a package setting into the machine's `settings:` in the
    /// configuration on this Mac (CLI 0.7.27+); `sync` applies it.
    func setZones(setting: String, machine: String, zones: [String]) throws {
        let result = try runner.runCapturing(
            executable: executable,
            args: DNSProviderSetup.zonesArguments(setting: setting, machine: machine, zones: zones),
            environment: environment()
        )
        try requireSuccess(result)
    }

    /// Stores a secret in the CLI's own store. The value goes to the
    /// command's standard input, never into its arguments.
    func setSecret(_ name: String, value: String) throws {
        guard let input = DNSProviderSetup.secretInput(value) else {
            throw DevmachineCLIError.commandFailed("The value is empty or has a line break in it.")
        }
        let result = try runner.runCapturing(
            executable: executable,
            args: DNSProviderSetup.secretArguments(credential: name),
            environment: environment(),
            input: input,
            onBytesWritten: nil
        )
        try requireSuccess(result)
    }

    func listWorkspaces() throws -> [CLIWorkspace] {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "workspaces", "list"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIWorkspaceList.self, from: Data(result.stdout.utf8)).workspaces
    }

    /// Every workspace with its settings, for the Workspaces page.
    func workspaceSummaries() throws -> [WorkspaceSummary] {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "workspaces", "list"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIWorkspaceDetailList.self, from: Data(result.stdout.utf8)).workspaces.map {
            WorkspaceSummary(
                name: $0.name, machine: $0.machine, user: $0.user, packages: $0.packages ?? [],
                settings: ($0.settings ?? [:]).mapValues(\.text), credentials: $0.credentials ?? [:])
        }
    }

    func listMachines() throws -> [CLIMachine] {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "machines", "list"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode([CLIMachine].self, from: Data(result.stdout.utf8))
    }

    /// `machines list`, decoded with every field `config show`'s `machines`
    /// carries (hosts included) — the same JSON shape, so the app can show a
    /// machine's address without a second call to `configShow()`.
    func listConfigMachines() throws -> [CLIConfigMachine] {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "machines", "list"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode([CLIConfigMachine].self, from: Data(result.stdout.utf8))
    }

    /// `machines show`: what `setup`, `sync` or `doctor` last read from the
    /// machine. It does not connect. Nil for a machine never read.
    func observed(machine: String) throws -> MachineObserved? {
        let result = try runner.runCapturing(
            executable: executable, args: MachineObserved.arguments(machine: machine), environment: environment())
        try requireSuccess(result)
        return MachineObserved.parse(result.stdout)
    }

    /// What the CLI read from each machine it reports a `platform` for: one
    /// with none was never read, or the CLI is too old to have `machines
    /// show`, so it is not asked. A read that fails leaves the machine out.
    func observed(of machines: [CLIConfigMachine]) -> [String: MachineObserved] {
        machines.filter { $0.platform != nil }.reduce(into: [:]) { result, machine in
            if let observed = try? observed(machine: machine.name) { result[machine.name] = observed }
        }
    }

    /// `machines rm`: takes the machine out of the configuration and leaves
    /// the server running. The CLI refuses while a workspace lives on it.
    func removeMachine(_ name: String) throws {
        let result = try runner.runCapturing(
            executable: executable, args: ["machines", "rm", name, "--yes"], environment: environment())
        try requireSuccess(result)
    }

    /// `machines edit <m> --location` (CLI 0.7.30+): the configuration only.
    func editLocation(machine: String, location: String) throws {
        let result = try runner.runCapturing(
            executable: executable, args: MachineLocation.editArguments(machine: machine, location: location),
            environment: environment())
        try requireSuccess(result)
    }

    /// `resolve --machine`: the addresses its `hosts` turn into from here.
    func addresses(machine: String) throws -> MachineAddresses {
        let result = try runner.runCapturing(
            executable: executable, args: MachineAddresses.arguments(machine: machine), environment: environment())
        try requireSuccess(result)
        guard let report = MachineAddresses.parse(result.stdout) else {
            throw DevmachineCLIError.commandFailed("The CLI gave no addresses for \(machine).")
        }
        return report
    }

    /// `credentials list --machine`: logs in to see what the machine has.
    func credentials(machine: String) throws -> MachineCredentials {
        let result = try runner.runCapturing(
            executable: executable, args: MachineCredentials.arguments(machine: machine), environment: environment())
        try requireSuccess(result)
        guard let report = MachineCredentials.parse(result.stdout) else {
            throw DevmachineCLIError.commandFailed("The CLI gave no credentials for \(machine).")
        }
        return report
    }

    /// `machines password-login`: logs in to ask sshd who can use a password.
    func passwordLogin(machine: String) throws -> MachinePasswordLogin {
        let result = try runner.runCapturing(
            executable: executable, args: MachinePasswordLogin.arguments(machine: machine), environment: environment())
        try requireSuccess(result)
        guard let report = MachinePasswordLogin.parse(result.stdout) else {
            throw DevmachineCLIError.commandFailed("The CLI said nothing about password login on \(machine).")
        }
        return report
    }

    /// `machines password-login --off|--keep|--on --yes`.
    func changePasswordLogin(machine: String, to change: PasswordLoginChange) throws {
        let result = try runner.runCapturing(
            executable: executable, args: change.arguments(machine: machine), environment: environment())
        try requireSuccess(result)
    }

    /// Every configured machine that is not this Mac — the set Stats and the
    /// package gate check, instead of only the first one.
    func nonSelfMachines() throws -> [CLIConfigMachine] {
        try listConfigMachines().filter { !$0.isSelf }
    }

    /// Where the CLI keeps its configuration — the folder the app used to ask
    /// the person to type by hand.
    func configPath() throws -> CLIConfigPath {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "config", "path"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIConfigPath.self, from: Data(result.stdout.utf8))
    }

    /// The host key a server presents, read without logging in or writing
    /// anything (CLI 0.7.27+): what the wizard shows before anything trusts it.
    func scanMachine(address: String, port: String) throws -> MachineScan {
        let result = try runner.runCapturing(
            executable: executable, args: MachineScan.arguments(address: address, port: port),
            environment: environment())
        try requireSuccess(result)
        guard let scan = MachineScan.parse(result.stdout) else {
            throw DevmachineCLIError.commandFailed("The CLI gave no fingerprint for \(address).")
        }
        return scan.asked(address: address, port: port)
    }

    /// The keys the SSH agent the CLI is handed holds, so a key chosen here
    /// is one `machines add --key agent:` can find. `ssh-add` exits 1 with
    /// no key and 2 when there is no agent to ask.
    func agentKeys() throws -> [AgentKey] {
        let result = try runner.runCapturing(
            executable: AgentKeyList.executable, args: AgentKeyList.arguments, environment: environment())
        guard result.exitCode == 0 || result.exitCode == 1 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw DevmachineCLIError.commandFailed(detail.isEmpty ? "The SSH agent did not answer." : detail)
        }
        return AgentKeyList.parse(result.stdout)
    }

    func version() throws -> String {
        let result = try runner.runCapturing(executable: executable, args: ["version"], environment: environment())
        try requireSuccess(result)
        return result.stdout
    }

    /// `packages outdated` (CLI 0.7.31+): the pinned packages release against
    /// the newest one. It reads and caches a release feed and never changes
    /// anything.
    func packagesOutdated() throws -> Data {
        let result = try runner.runCapturing(
            executable: executable, args: ["packages", "outdated", "--format", "json"], environment: environment())
        try requireSuccess(result)
        return Data(result.stdout.utf8)
    }

    /// `widgets list --format json`: the widgets this machine's packages
    /// offer. One bad widget is reported in `problems`, never a failure.
    func widgetsList() throws -> Data {
        let result = try runner.runCapturing(
            executable: executable, args: ["widgets", "list", "--format", "json"], environment: environment())
        if result.exitCode != 0, result.stderr.contains("unknown command \"widgets\"") {
            throw DevmachineCLIError.needsNewerCLI("widgets")
        }
        try requireSuccess(result)
        return Data(result.stdout.utf8)
    }

    /// The tmux sessions of every named workspace in one call. A workspace
    /// that could not be listed carries its `error`; the call itself fails
    /// only when the CLI cannot run it at all.
    func sessions(workspaces: [String]) throws -> CLISessionList {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "sessions"] + workspaces.flatMap { ["--workspace", $0] },
            environment: environment())
        if result.exitCode != 0, result.stderr.contains("unknown command \"sessions\"") {
            throw DevmachineCLIError.needsNewerCLI("sessions")
        }
        try requireSuccess(result)
        return try JSONDecoder().decode(CLISessionList.self, from: Data(result.stdout.utf8))
    }

    /// `packages add|rm`: changes the configuration only; a sync applies it.
    func runPackageEdit(_ arguments: [String]) throws {
        let result = try runner.runCapturing(executable: executable, args: arguments, environment: environment())
        try requireSuccess(result)
    }

    /// Every machine and workspace the CLI knows about, plus the base domain
    /// new subdomains are created under.
    func configShow() throws -> CLIConfigShow {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "config", "show"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIConfigShow.self, from: Data(result.stdout.utf8))
    }

    /// The exact ssh `Host` entry name for every workspace, as the CLI wrote
    /// it to `~/.ssh/config` — the app no longer has to guess a suffix.
    func aliases() throws -> [CLIAlias] {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "aliases"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIAliasList.self, from: Data(result.stdout.utf8)).aliases
    }

    func aliasListing() throws -> CLIAliasListing {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "aliases"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIAliasListing.self, from: Data(result.stdout.utf8))
    }

    /// Every package the CLI knows about, and which machine or workspace has
    /// it — used to check whether a machine has `devmachine-app` before the
    /// app relies on it for stats or Caddy logs.
    func packages() throws -> [CLIPackage] {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "packages", "list"],
            environment: environment()
        )
        try requireSuccess(result)
        return try JSONDecoder().decode(CLIPackageList.self, from: Data(result.stdout.utf8)).packages
    }

    /// The first configured server, for onboarding's "is a server set up"
    /// check only. `self` is the Mac the app runs on, never the answer. A
    /// command that acts on a server names its machine instead of asking
    /// this: with several, the first one is a guess.
    func resolveAdminMachine() throws -> String {
        let machines = try listMachines()
        guard let machine = machines.first(where: { !$0.isSelf }) else {
            throw DevmachineCLIError.commandFailed(
                "No machine is configured. Run `devmachine machines add` first.")
        }
        return machine.name
    }

    /// Runs a shell command as `machine`'s admin, through the CLI's own
    /// connection (reused for 5 minutes, host key checked, the configured key
    /// or agent, the address fallback including tailscale) — never a raw ssh
    /// alias, which a machine's admin login may have no `~/.ssh/config` entry
    /// for.
    func run(machine: String, command: String) throws -> String {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["run", "--machine", machine, "--", command],
            environment: environment()
        )
        try requireSuccess(result)
        return result.stdout
    }

    /// Runs a command from a package installed on `machine`'s admin account —
    /// `devmachine-app`'s `stats` and `caddy-logs`. Distinct from `run(machine:command:)`,
    /// which runs a plain shell snippet: this goes through the package's own
    /// entrypoint, so the machine needs the package installed (`packages()`
    /// checks that first) and a released version new enough to accept the
    /// command (`DevmachineCLIError.commandFailed` with `isUnknownPackageCommand`).
    func run(machine: String, package: String, args: [String]) throws -> String {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["run", "--machine", machine, "--package", package, "--"] + args,
            environment: environment()
        )
        try requireSuccess(result, reportingAs: package == MachinePrepare.package ? (machine, nil) : nil)
        return result.stdout
    }

    /// `devmachine tunnel`, as a command line to spawn and keep: it holds its
    /// ssh open until it is stopped, so it cannot go through `runner`.
    func tunnelCommand(workspace: String, remotePort: Int, localPort: Int)
        -> (executable: String, args: [String], environment: [String: String]) {
        (executable,
         ["tunnel", workspace, String(remotePort), "--local", String(localPort)],
         environment())
    }

    /// What `doctor` produced: a parsed report, or — when the CLI printed a
    /// text table this app's parser does not recognize — its raw stdout, so
    /// nothing is thrown away just because it could not be parsed.
    enum DoctorOutcome: Equatable, Sendable {
        case report(DoctorReport)
        case raw(String)
    }

    /// `devmachine doctor --machine <machine>`: the health of a configured,
    /// non-self machine.
    func doctor(machine: String) throws -> DoctorOutcome {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "doctor", "--machine", machine],
            environment: environment()
        )
        return try doctorOutcome(from: result)
    }

    /// `devmachine machine doctor`: what this Mac itself is missing, for the
    /// configured self machine.
    func machineDoctor() throws -> DoctorOutcome {
        let result = try runner.runCapturing(
            executable: executable,
            args: ["--format", "json", "machine", "doctor"],
            environment: environment()
        )
        return try doctorOutcome(from: result)
    }

    // `doctor` exits 1 when a check fails — that is its normal, informative
    // result, not a command failure, so the exit code is never used to decide
    // whether this throws. Only stdout that carries nothing usable at all
    // (the command could not even start reporting) is a real failure.
    private func doctorOutcome(
        from result: (stdout: String, stderr: String, exitCode: Int32)
    ) throws -> DoctorOutcome {
        if let report = DoctorParser.parse(result.stdout) {
            return .report(report)
        }
        if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .raw(result.stdout)
        }
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        throw DevmachineCLIError.commandFailed(detail.isEmpty ? "Devmachine CLI failed." : detail)
    }

    /// The context engine, reached as `devmachine-app`'s `context` entrypoint.
    /// A workspace session runs it over the CLI's own ssh, as that workspace's
    /// account.
    func context(workspace: String, session: String) throws -> String {
        let result = try runner.runCapturing(
            executable: executable,
            args: [
                "run", "--workspace", workspace, "--package", "devmachine-app",
                "--", "context", "--session", session,
            ],
            environment: environment()
        )
        try requireSuccess(result, reportingAs: (nil, workspace))
        return result.stdout
    }

    /// The same engine, run locally by the CLI on the named self machine.
    func context(machine: String, project: String) throws -> String {
        let result = try runner.runCapturing(
            executable: executable,
            args: [
                "run", "--machine", machine, "--package", "devmachine-app",
                "--", "context", "--project", project,
            ],
            environment: environment()
        )
        try requireSuccess(result, reportingAs: (machine, nil))
        return result.stdout
    }

    // An app opened from the Dock inherits launchd's empty SSH agent, not the
    // shell's, so the CLI needs an explicit socket the same way a terminal
    // does: an override from Settings, else the 1Password agent if it is
    // actually there, else whatever this process inherited.
    func environment() -> [String: String] {
        var environment = processEnvironment
        let socket = RemoteCommands.sshAuthSocket(
            customSocket: customSocket, fileExists: socketFileExists, environment: processEnvironment)
        environment["SSH_AUTH_SOCK"] = socket
        return environment
    }

    func requireSuccess(
        _ result: (stdout: String, stderr: String, exitCode: Int32),
        reportingAs package: (machine: String?, workspace: String?)? = nil
    ) throws {
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            if let package {
                PackageCallReports.post(machine: package.machine, workspace: package.workspace, detail: detail)
            }
            throw DevmachineCLIError.commandFailed(detail.isEmpty ? "Devmachine CLI failed." : detail)
        }
    }
}
