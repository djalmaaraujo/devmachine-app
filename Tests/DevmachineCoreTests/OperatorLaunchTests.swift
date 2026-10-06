import XCTest
@testable import DevmachineCore

final class OperatorLaunchTests: XCTestCase {
    func testTheFirstOpenOffersEveryInstalledHarnessInOrder() {
        XCTAssertEqual(
            OperatorLaunch.plan(isRunning: false, saved: nil, installed: [.claude, .codex, .pi]),
            .choose([.claude, .codex, .pi], last: nil))
    }

    func testWithNoHarnessInstalledItOpensTheTerminalWithoutAsking() {
        XCTAssertEqual(OperatorLaunch.plan(isRunning: false, saved: nil, installed: []), .start(.terminal))
        XCTAssertEqual(OperatorLaunch.plan(isRunning: false, saved: .terminal, installed: []), .start(.terminal))
    }

    func testAnEndedSessionAsksAgainWithTheLastPickSelected() {
        XCTAssertEqual(
            OperatorLaunch.plan(isRunning: false, saved: .harness(.pi), installed: [.claude, .pi]),
            .choose([.claude, .pi], last: .harness(.pi)))
        XCTAssertEqual(
            OperatorLaunch.plan(isRunning: false, saved: .terminal, installed: [.claude]),
            .choose([.claude], last: .terminal))
    }

    func testARunningSessionIsShownAndNothingIsTyped() {
        XCTAssertEqual(OperatorLaunch.plan(isRunning: true, saved: nil, installed: [.claude]), .attach)
        XCTAssertEqual(OperatorLaunch.plan(isRunning: true, saved: .harness(.claude), installed: [.claude]), .attach)
    }
}

final class AppSettingsOperatorTests: XCTestCase {
    private let legacy = #"{"opsRepoPath":"/Users/alice/.config/devmachine","hostAlias":"","publicIP":"203.0.113.10","baseDomain":"example.com"}"#

    func testSettingsWrittenBeforeTheOperatorChoiceDecodeAsNotChosenAndEnabled() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertNil(settings.operatorProgram)
        XCTAssertTrue(settings.operatorSessionEnabled)
    }

    func testANewSettingsValueHasTheOperatorOnAndNotChosen() {
        XCTAssertNil(AppSettings.empty.operatorProgram)
        XCTAssertTrue(AppSettings.empty.operatorSessionEnabled)
    }

    func testTheOperatorChoiceAndSwitchSurviveARoundTrip() throws {
        var settings = AppSettings.empty
        settings.operatorProgram = .harness(.codex)
        settings.operatorSessionEnabled = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.operatorProgram, .harness(.codex))
        XCTAssertFalse(decoded.operatorSessionEnabled)
    }

    func testTerminalOnlyIsAChoiceToo() throws {
        var settings = AppSettings.empty
        settings.operatorProgram = .terminal
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.operatorProgram, .terminal)
    }

    func testAHarnessNotTurnedOnIsKeptAsTheOperatorChoice() {
        var settings = AppSettings.empty
        settings.enabledHarnesses = [.claude]
        settings.operatorProgram = .harness(.pi)
        settings.enabledHarnesses = []
        XCTAssertEqual(settings.operatorProgram, .harness(.pi))
    }
}
