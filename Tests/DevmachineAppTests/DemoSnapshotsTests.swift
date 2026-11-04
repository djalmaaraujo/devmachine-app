import XCTest
import DevmachineCore
@testable import DevmachineApp

@MainActor
final class DemoSnapshotsTests: XCTestCase {
    override func tearDown() async throws {
        unsetenv("DEVMACHINE_DEMO")
        unsetenv("DEVMACHINE_DEMO_SNAPSHOTS")
        unsetenv("DEVMACHINE_DEMO_LOADING")
        DemoSnapshots.subdomainsInitialTab = .sites
        DemoSnapshots.setupInitialSection = .general
        DemoSnapshots.paletteInitialQuery = ""
        DemoData.typedAtPrompt = [:]
        try await super.tearDown()
    }

    func testTargetDirectoryIsNilWithNeitherVariableSet() {
        unsetenv("DEVMACHINE_DEMO")
        unsetenv("DEVMACHINE_DEMO_SNAPSHOTS")
        XCTAssertNil(DemoSnapshots.targetDirectory)
    }

    func testTargetDirectoryIsNilWithoutDemoMode() {
        unsetenv("DEVMACHINE_DEMO")
        setenv("DEVMACHINE_DEMO_SNAPSHOTS", "/tmp/devmachine-shots", 1)
        XCTAssertNil(DemoSnapshots.targetDirectory)
    }

    func testTargetDirectoryIsNilWithDemoModeButNoSnapshotDirectory() {
        setenv("DEVMACHINE_DEMO", "1", 1)
        unsetenv("DEVMACHINE_DEMO_SNAPSHOTS")
        XCTAssertNil(DemoSnapshots.targetDirectory)
    }

    func testTargetDirectoryIsNilForAnEmptyPath() {
        setenv("DEVMACHINE_DEMO", "1", 1)
        setenv("DEVMACHINE_DEMO_SNAPSHOTS", "", 1)
        XCTAssertNil(DemoSnapshots.targetDirectory)
    }

    func testTargetDirectoryReadsTheGivenPath() {
        setenv("DEVMACHINE_DEMO", "1", 1)
        setenv("DEVMACHINE_DEMO_SNAPSHOTS", "/tmp/devmachine-shots", 1)
        XCTAssertEqual(DemoSnapshots.targetDirectory?.path, "/tmp/devmachine-shots")
    }

    func testEveryScreenHasAUniqueNumberedFileName() {
        let names = DemoSnapshots.screens.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
        for name in names {
            XCTAssertTrue(name.hasSuffix(".png"))
        }
    }

    func testScreensAreNumberedInCaptureOrder() {
        let numbers = DemoSnapshots.screens.map { screen in
            String(screen.fileName.prefix(while: \.isNumber))
        }
        XCTAssertEqual(numbers, numbers.sorted())
        XCTAssertEqual(numbers.first, "01")
        XCTAssertEqual(numbers.last, "28")
    }

    func testEveryScreenHasAUniqueID() {
        let ids = DemoSnapshots.screens.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryScreenWaitsBeforeItIsCaptured() {
        for screen in DemoSnapshots.screens {
            XCTAssertGreaterThan(screen.settleNanoseconds, 0)
        }
    }

    func testTheWalkWritesEveryImageTheWebsiteShows() {
        XCTAssertEqual(DemoSnapshots.screens.map(\.fileName), [
            "01-sessions.png", "02-session-claude.png", "03-pull-requests.png",
            "04-subdomains-sites.png", "05-subdomains-dns-cloudflare.png", "06-stats.png",
            "07-settings-health.png", "08-session-defaults.png", "09-onboarding.png",
            "10-publish-port.png", "18-operator.png", "19-home.png",
            "20-menubar-usage.png", "21-command-palette.png", "22-drop-files.png",
            "23-preview.png", "24-scheduled.png", "25-quick-panel.png", "26-chats.png", "27-ask.png",
            "28-sidebar-nav.png",
        ])
    }

    func testThePreviewAndScheduledScreensComeBeforeTheChatsScreens() {
        XCTAssertEqual(DemoSnapshots.screens.suffix(6).prefix(2).map(\.id), ["preview", "scheduled"])
    }

    func testTheChatsScreensCloseTheWalkWithAskZoomed() {
        let last = Array(DemoSnapshots.screens.suffix(4))
        XCTAssertEqual(last.map(\.id), ["quick-panel-answer", "chat-main", "context-ask-claude", "sidebar-nav"])
        XCTAssertEqual(last.map(\.zoom), [nil, nil, "context:ask", nil])
        XCTAssertEqual(last[2].windowSize, NSSize(width: 1600, height: 1000))
    }

    func testAZoomThatReachesThePaneWidensToItsLeftEdgeAndKeepsTheShape() {
        let size = CGSize(width: 1600, height: 1000)
        let ask = CGRect(x: 1250, y: 600, width: 330, height: 380)
        let rect = DemoSnapshots.zoomRect(around: ask, in: size, zoom: 1.8, left: 260)
        XCTAssertEqual(rect.minX, 260)
        XCTAssertEqual(rect.maxX, ask.maxX)
        XCTAssertEqual(rect.width / rect.height, 1.6, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 1000)
        XCTAssertEqual(DemoSnapshots.zoomLeftEdge(for: "context:ask", frames: ["pane:main": CGRect(x: 260, y: 0, width: 1, height: 1)]), 260)
        XCTAssertNil(DemoSnapshots.zoomLeftEdge(for: "context:todo", frames: ["pane:main": .zero]))
    }

    func testAZoomRectKeepsTheViewShapeAndStaysInside() {
        let size = CGSize(width: 1600, height: 1000)
        let rect = DemoSnapshots.zoomRect(around: CGRect(x: 1500, y: 900, width: 80, height: 80), in: size, zoom: 2)
        XCTAssertEqual(rect, CGRect(x: 800, y: 500, width: 800, height: 500))
        let centred = DemoSnapshots.zoomRect(around: CGRect(x: 700, y: 450, width: 200, height: 100), in: size, zoom: 2)
        XCTAssertEqual(centred, CGRect(x: 400, y: 250, width: 800, height: 500))
    }

    func testThePreviewScreenOpensAnAcmeDevServerSession() {
        XCTAssertEqual(DemoSnapshots.previewSession.alias, "acme-devmachine")
        XCTAssertTrue(DemoData.sessionsByAlias["acme-devmachine"]?.contains {
            $0.name == DemoSnapshots.previewSession.name } ?? false)
    }

    func testTheDropScreenTargetsAcmesClaudeSession() {
        XCTAssertEqual(
            DemoSnapshots.dropKind,
            .remote(alias: "acme-devmachine", session: "claude \u{2014} payments refactor"))
        let sessions = DemoData.sessionsByAlias["acme-devmachine"]?.map(\.name) ?? []
        guard case let .remote(_, session) = DemoSnapshots.dropKind else {
            return XCTFail("the drop screen must show a remote session")
        }
        XCTAssertTrue(sessions.contains(session))
    }

    func testTheDroppedPathIsWhatAClaudeUploadTypes() {
        XCTAssertEqual(
            DemoSnapshots.droppedPath,
            "/home/acme/.claude/image-cache/devmachine-app/mockup-20260930-143012.png")
    }

    func testTheDropScreenTypesTheSentenceAroundThePath() {
        XCTAssertEqual(
            DemoSnapshots.dropPrompt,
            "look at /home/acme/.claude/image-cache/devmachine-app/mockup-20260930-143012.png"
            + " and match the header")
    }

    func testThePaletteOpensEmptyOutsideTheScreenshotWalk() {
        XCTAssertEqual(DemoSnapshots.paletteInitialQuery, "")
    }

    func testHomeIsCapturedAsNineteen() {
        XCTAssertEqual(DemoSnapshots.screens.first { $0.id == "home" }?.fileName, "19-home.png")
    }

    func testTheOperatorScreenSelectsTheOperatorSession() {
        XCTAssertEqual(
            DemoSnapshots.operatorSelection,
            .localSession(name: Workspace.operatorSession, path: DemoData.operatorPath))
    }

    func testSubdomainsInitialTabDefaultsToSites() {
        XCTAssertEqual(DemoSnapshots.subdomainsInitialTab, .sites)
    }

    func testSetupInitialSectionDefaultsToConnection() {
        XCTAssertEqual(DemoSnapshots.setupInitialSection, .general)
    }
    func testTheLoadingWalkFollowsTheMainWalksNumbering() {
        let names = DemoSnapshots.skeletonScreens.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(Set(names).isDisjoint(with: DemoSnapshots.screens.map(\.fileName)))
        let numbers = names.map { String($0.prefix(while: \.isNumber)) }
        XCTAssertEqual(numbers, numbers.sorted())
        XCTAssertEqual(numbers.first, "11")
    }

    func testLoadingIsHeldOnlyInsideDemoMode() {
        setenv("DEVMACHINE_DEMO_LOADING", "1", 1)
        unsetenv("DEVMACHINE_DEMO")
        XCTAssertFalse(DemoMode.holdsLoading)
        setenv("DEVMACHINE_DEMO", "1", 1)
        XCTAssertTrue(DemoMode.holdsLoading)
    }

    func testAWindowSizeIsReadAsWidthByHeight() {
        XCTAssertEqual(DemoSnapshots.parseWindowSize("1100x700"), NSSize(width: 1100, height: 700))
        XCTAssertNil(DemoSnapshots.parseWindowSize("1100"))
        XCTAssertNil(DemoSnapshots.parseWindowSize("100x100"))
    }

    func testTheWalkIsCapturedAtABigScreenWindowSize() {
        unsetenv("DEVMACHINE_DEMO_WINDOW")
        XCTAssertEqual(DemoSnapshots.windowSize, NSSize(width: 2000, height: 1120))
    }

    func testMenubarPanesAndTheSheetAreFramedAsPanels() {
        let panels = DemoSnapshots.screens.filter { DemoSnapshots.chrome(for: $0.id) == .panel }.map(\.id)
        XCTAssertEqual(panels, ["pull-requests", "publish-port", "menubar-usage", "quick-panel-answer"])
    }

    func testEveryOtherScreenIsFramedAsAWindow() {
        XCTAssertEqual(DemoSnapshots.chrome(for: "home"), .window)
        XCTAssertEqual(DemoSnapshots.chrome(for: "onboarding"), .window)
    }

    func testTheUsagePaneIsTallEnoughForEveryModelRow() {
        XCTAssertEqual(DemoSnapshots.usagePaneHeight, 700)
    }

    func testTheWorkspacesWalkShowsTheListEveryFlowAndEachRunState() {
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "workspaces"]).map(\.id), [
            "workspaces-list", "workspaces-new", "workspaces-new-taken", "workspaces-review", "workspaces-running",
            "workspaces-failed", "workspaces-done", "workspaces-edit", "workspaces-edit-review", "workspaces-forget",
            "workspaces-forget-refused", "workspaces-destroy", "workspaces-reopened", "workspaces-new-no-agents",
            "workspaces-harnesses",
        ])
    }

    func testTheMapWallpaperWalkShowsHomeWithBothMapSizesAndTheAppearanceBackgroundPicker() {
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "map-wallpaper"]).map(\.id), [
            "map-wallpaper-home", "map-wallpaper-fleet", "map-wallpaper-empty", "map-wallpaper-appearance",
            "map-wallpaper-large", "map-wallpaper-large-fleet", "map-wallpaper-appearance-photo",
            "map-wallpaper-appearance-gradient", "map-wallpaper-sidebar-collapsed",
            "map-wallpaper-large-collapsed", "map-wallpaper-large-fleet-collapsed",
        ])
        XCTAssertEqual(DemoMapWallpaper.choice(for: "map-wallpaper-large-fleet-collapsed"), .networkMap(.large))
        XCTAssertEqual(DemoMapWallpaper.choice(for: "map-wallpaper-home"), .networkMap(.compact))
        XCTAssertEqual(DemoMapWallpaper.choice(for: "map-wallpaper-large"), .networkMap(.large))
        XCTAssertEqual(DemoMapWallpaper.choice(for: "map-wallpaper-appearance"), .networkMap(.large))
    }

    func testTheHostKeyWalkIsItsOwnSetOfPanelsPickedByTheEnvironment() {
        let screens = DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "host-key"])
        XCTAssertEqual(screens.map(\.id), ["hostkey-review", "hostkey-matching", "hostkey-older-cli", "hostkey-failed"])
        XCTAssertTrue(Set(screens.map(\.fileName)).isDisjoint(with: DemoSnapshots.screens.map(\.fileName)))
        for screen in screens {
            XCTAssertEqual(DemoSnapshots.chrome(for: screen.id), .panel, screen.id)
        }
    }

    func testEveryHostKeyDemoScreenEndsInTheStateItIsNamedFor() async {
        let expected: [String: (HostKeyPhase?) -> Bool] = [
            "hostkey-review": { if case .review = $0 { return true } else { return false } },
            "hostkey-matching": { $0 == .matching },
            "hostkey-older-cli": { $0 == .needsNewerCLI },
            "hostkey-failed": { if case .failed = $0 { return true } else { return false } },
        ]
        for screen in DemoHostKey.screens {
            let output = DemoHostKey.output(for: screen.id)
            let phase = HostKeyStore.phase(afterCheck: output, machine: DemoHostKey.machine)
            XCTAssertEqual(expected[screen.id]?(phase), true, screen.id)
        }
    }

    func testTheWorktreeWalkIsItsOwnSetAndPickedByTheEnvironment() {
        let names = DemoSnapshots.worktreeScreens.map(\.fileName)
        XCTAssertEqual(names, [
            "31-git-worktrees.png", "32-worktree-remove.png", "33-worktrees-merged.png", "34-worktree-foreign.png",
        ])
        XCTAssertTrue(Set(names).isDisjoint(with: DemoSnapshots.screens.map(\.fileName)))
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "worktrees"]).map(\.id),
                       DemoSnapshots.worktreeScreens.map(\.id))
        XCTAssertEqual(DemoSnapshots.walk(environment: [:]).map(\.id), DemoSnapshots.screens.map(\.id))
        XCTAssertEqual(
            DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "setup-flow", "DEVMACHINE_DEMO_ONLY": "setup-local, setup-review"])
                .map(\.id),
            ["setup-local", "setup-review"])
    }

    func testTheSizingWalkCapturesEveryScreenATextSizeChangeTouches() {
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "sizing"]).map(\.id), [
            "sessions", "session-claude", "session-defaults", "subdomains-sites", "stats",
            "update-toast", "publish-port", "command-palette",
        ])
        let names = DemoSnapshots.sizingScreens.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("4") })
    }

    func testTheTextSizeOfAWalkComesFromTheEnvironmentAndStaysInRange() {
        XCTAssertNil(DemoSnapshots.uiScale(environment: [:]))
        XCTAssertNil(DemoSnapshots.uiScale(environment: ["DEVMACHINE_DEMO_UI_SCALE": "big"]))
        XCTAssertEqual(DemoSnapshots.uiScale(environment: ["DEVMACHINE_DEMO_UI_SCALE": "1.6"]), 1.6)
        XCTAssertEqual(DemoSnapshots.uiScale(environment: ["DEVMACHINE_DEMO_UI_SCALE": "3"]), 1.6)
    }

    func testTheHarnessIconWalkCapturesTheSidebarOnItsOwn() {
        XCTAssertEqual(DemoSnapshots.harnessIconScreens.map(\.fileName), ["35-sidebar-harness-icons.png"])
        XCTAssertEqual(DemoSnapshots.tabsScreens.map(\.fileName),
                       ["36-tabs-open.png", "37-tabs-sidebar-closed.png", "38-tabs-other-workspace.png", "39-tabs-file.png"])
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "tabs"]).map(\.id),
                       ["tabs-open", "tabs-sidebar-closed", "tabs-other-workspace", "tabs-file"])
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "harness-icons"]).map(\.id),
                       DemoSnapshots.harnessIconScreens.map(\.id))
    }

    func testTheUpdateToastWalkIsItsOwnSet() {
        let names = DemoSnapshots.updateToastScreens.map(\.fileName)
        XCTAssertEqual(names, [
            "36-update-toast.png", "37-update-toast-large-text.png",
            "38-update-toast-relaunching.png", "39-update-toast-installed.png",
        ])
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "update-toast"]).map(\.id),
                       DemoSnapshots.updateToastScreens.map(\.id))
        for screen in DemoSnapshots.updateToastScreens {
            XCTAssertEqual(DemoSnapshots.chrome(for: screen.id), .panel)
        }
    }

    func testTheCLIUpdateWalkEndsWithTheCornerToastAsPanels() {
        let toasts = DemoSnapshots.cliUpdateScreens.filter { $0.id.hasPrefix("cli-update-toast") }
        XCTAssertEqual(toasts.map(\.fileName), [
            "65-cli-update-toast.png", "66-cli-update-toast-running.png", "67-cli-update-toast-updated.png",
            "68-cli-update-toast-failed.png", "69-cli-update-toast-manual.png", "57-cli-update-toast-pinned.png",
        ])
        for screen in toasts {
            XCTAssertEqual(DemoSnapshots.chrome(for: screen.id), .panel)
        }
        XCTAssertEqual(DemoSnapshots.chrome(for: "cli-update-available"), .window)
    }

    func testTheCLIUpdateWalkHasThePackagesCardInEachState() {
        let cards = DemoSnapshots.cliUpdateScreens.filter { $0.id.hasPrefix("packages-update-toast") }
        XCTAssertEqual(cards.map(\.fileName), [
            "53-packages-update-toast.png", "54-packages-update-toast-running.png",
            "55-packages-update-toast-done.png", "56-packages-update-toast-failed.png",
        ])
        for screen in cards {
            XCTAssertEqual(DemoSnapshots.chrome(for: screen.id), .panel)
        }
        let names = DemoSnapshots.cliUpdateScreens.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testTheCLIUpdateWalkShowsTheUpdateDialogWithItsSteps() {
        let dialog = DemoSnapshots.cliUpdateScreens.first { $0.id == "update-dialog-steps" }
        XCTAssertEqual(dialog?.fileName, "205-update-dialog-steps.png")
        XCTAssertEqual(DemoSnapshots.chrome(for: "update-dialog-steps"), .panel)
    }

    func testTheMachineReadyWalkIsItsOwnSet() {
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "machine-ready"]).map(\.id), [
            "ready-home", "ready-running", "ready-failed", "ready-done", "ready-first-sync", "ready-old-cli",
            "ready-outdated", "install-cli", "install-cli-running", "install-cli-failed",
        ])
        XCTAssertEqual(Set(DemoSnapshots.machineReadyScreens.map(\.fileName)).count, 10)
    }

    func testThePackagesWalkIsItsOwnSet() {
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "packages"]).map(\.id), [
            "packages-all", "packages-selected", "packages-confirm", "packages-pending", "packages-running",
            "packages-succeeded", "packages-failed", "packages-mac",
        ])
        XCTAssertEqual(Set(DemoSnapshots.packagesScreens.map(\.fileName)).count, 8)
    }

    func testThePackagesWalkShowsALinuxPackageOnARemoteMac() throws {
        let snapshot = DemoPackages.macSnapshot()
        let page = DemoPackages.page(for: "packages-mac")
        let focus = page.focus(in: snapshot.targets)
        let statuses = PackagesSettingsView.statuses(snapshot)
        let fit = { (name: String) in
            snapshot.systemFit(try XCTUnwrap(snapshot.entries.first { $0.name == name }), on: focus, statuses: statuses)
        }
        XCTAssertEqual(focus, [.machine("studio", isSelf: false)])
        XCTAssertEqual(try fit("docker"), .blocked("Linux only"))
        XCTAssertEqual(try fit("mac-ports"), .fits)
        XCTAssertEqual(try fit("git"), .fits)
    }

    func testThePackagesWalkOpensPostgresAndSendsTwoPackagesToAMachineAndAWorkspace() {
        let page = DemoPackages.page(for: "packages-selected")
        XCTAssertEqual(page.expanded, "postgres")
        XCTAssertEqual(page.selection, ["postgres", "nodejs"])
        let batch = PackagesSettingsView.plan(
            page.selection.sorted(), on: [DemoPackages.target, .workspace("acme", machine: "main")], .install,
            snapshot: DemoPackages.snapshot(after: .none))
        XCTAssertEqual(batch.edits.map(\.changes), [
            PackageChanges(adds: ["postgres"], removes: []),
        ])
        XCTAssertNil(DemoPackages.page(for: "packages-all").expanded)
        XCTAssertTrue(DemoPackages.page(for: "packages-pending").selection.isEmpty)
    }

    func testThePackagesWalkShowsEveryPillOnMain() {
        let statuses = DemoPackages.snapshot(after: .none).statuses(for: DemoPackages.target)
        XCTAssertEqual(statuses["redis"], .applied)
        XCTAssertEqual(statuses["git"], .appliedAsDependency(of: "essentials"))
        XCTAssertEqual(statuses["tailscale"], .pendingInstall)
        XCTAssertEqual(statuses["postgres"], .available)
        let saved = DemoPackages.snapshot(after: .saved).statuses(for: DemoPackages.target)
        XCTAssertEqual(saved["postgres"], .pendingInstall)
        XCTAssertEqual(saved["redis"], .pendingRemove)
        let synced = DemoPackages.snapshot(after: .synced).statuses(for: DemoPackages.target)
        XCTAssertEqual(synced["postgres"], .applied)
        XCTAssertEqual(synced["redis"], .available)
    }

    func testThePackagesWalksJobIsTheSyncTheSelectionAsksFor() {
        let pending = DemoPackages.job(.pending)
        XCTAssertEqual(
            pending.request, SyncRequest(machine: "main", tags: ["postgres"], full: true, reasons: ["Packages"]))
        XCTAssertEqual(pending.plan.title, "Sync main")
        XCTAssertEqual(DemoPackages.job(.running(step: 0)).plan.steps, [["sync", "--machine", "main", "--yes"]])
        XCTAssertTrue(DemoPackages.job(.running(step: 0)).expanded)
    }

    func testTheFileViewerWalkIsItsOwnSet() {
        XCTAssertEqual(DemoSnapshots.fileViewerScreens.map(\.fileName), ["40-file-viewer.png"])
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "file-viewer"]).map(\.id),
                       DemoSnapshots.fileViewerScreens.map(\.id))
        XCTAssertEqual(DemoSnapshots.chrome(for: "file-viewer"), .panel)
        let data = Data(DemoSnapshots.fileViewerCode.utf8)
        let preview = FilePreviewReader.parse(
            "\(data.count)\u{1e}" + data.base64EncodedString(), path: DemoSnapshots.fileViewerPath)
        XCTAssertEqual(preview?.kind, .code(language: "swift"))
    }

    func testTheDNSSetupWalkIsItsOwnSet() {
        XCTAssertEqual(DemoSnapshots.walk(environment: ["DEVMACHINE_DEMO_WALK": "dns-setup"]).map(\.id), [
            "dns-none", "dns-not-synced", "dns-no-zones", "dns-syncing", "dns-failed", "dns-ready",
            "dns-chooser-godaddy", "dns-settings",
        ])
        XCTAssertEqual(Set(DemoSnapshots.dnsSetupScreens.map(\.fileName)).count, 8)
    }

    func testDemoDNSDataOffersGoDaddy() {
        XCTAssertEqual(DemoData.dnsProviders, ["cloudflare", "godaddy", "hostinger"])
        XCTAssertEqual(DemoData.dnsPackages.map(\.name), ["cloudflare", "godaddy", "hostinger"])
        XCTAssertEqual(DemoData.dnsRecordsByProvider["godaddy"]?.count, 1)
    }

    func testTheChooserScenariosHaveNoSitesOnMain() {
        DemoData.dnsScenario = .noneInstalled
        XCTAssertEqual(DemoData.subdomainStates["main"]?.rows, [])
        DemoData.dnsScenario = .noZones
        XCTAssertEqual(DemoData.subdomainStates["main"]?.rows.count, 3)
        DemoData.dnsScenario = .ready
    }
}
