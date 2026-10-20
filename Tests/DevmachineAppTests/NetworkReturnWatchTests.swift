import XCTest
@testable import DevmachineApp

final class NetworkReturnWatchTests: XCTestCase {
    private let offline = PathSnapshot(satisfied: false, interfaces: [])
    private let wifi = PathSnapshot(satisfied: true, interfaces: ["en0"])
    private let wifiAndTailscale = PathSnapshot(satisfied: true, interfaces: ["en0", "utun4"])

    func testTheNetworkComingBackIsAReturn() {
        XCTAssertTrue(PathSnapshot.returned(from: offline, to: wifi))
    }

    func testANewInterfaceIsAReturn() {
        XCTAssertTrue(PathSnapshot.returned(from: wifi, to: wifiAndTailscale))
    }

    func testLosingTheNetworkIsNotAReturn() {
        XCTAssertFalse(PathSnapshot.returned(from: wifi, to: offline))
    }

    func testTheSamePathAgainIsNotAReturn() {
        XCTAssertFalse(PathSnapshot.returned(from: wifi, to: wifi))
    }
}

final class TerminalActivityTests: XCTestCase {
    func testKeepsTheLastOutputPerWorkspace() {
        let activity = TerminalActivity()
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        activity.record(alias: "acme-devmachine", at: early)
        activity.record(alias: "acme-devmachine", at: late)

        XCTAssertEqual(activity.lastOutput(alias: "acme-devmachine"), late)
        XCTAssertNil(activity.lastOutput(alias: "beta-devmachine"))
    }
}
