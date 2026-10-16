import XCTest
@testable import DevmachineCore

final class LocalSyncsTests: XCTestCase {
    func testFindsASyncAndTheMachineItNames() {
        let listing = """
          10     1 /bin/zsh
          20    10 /opt/homebrew/bin/devmachine sync --machine main --yes
          30    10 devmachine --machine=edge sync --check
          40    10 /opt/homebrew/bin/devmachine sync
        """
        XCTAssertEqual(LocalSyncs.parse(listing), [
            LocalSync(pid: 20, machine: "main", byOperator: false),
            LocalSync(pid: 30, machine: "edge", byOperator: false),
            LocalSync(pid: 40, machine: nil, byOperator: false),
        ])
    }

    func testOtherCommandsAreNotSyncs() {
        let listing = """
          20     1 /opt/homebrew/bin/devmachine workspaces add acme
          21     1 /opt/homebrew/bin/devmachine --machine sync doctor
          22     1 /usr/bin/grep devmachine sync
          23     1 /bin/zsh -c devmachine-app sync
        """
        XCTAssertEqual(LocalSyncs.parse(listing), [])
    }

    func testASyncBelowTheOperatorIsTheOperators() {
        let listing = """
          88     1 zmx Operator
          89    88 /bin/zsh
          90    89 claude
          91    90 /opt/homebrew/bin/devmachine sync --yes
          95     1 /opt/homebrew/bin/devmachine sync --check
        """
        XCTAssertEqual(LocalSyncs.parse(listing, operatorPID: 88).map(\.byOperator), [true, false])
    }

    func testASyncWithoutAMachineCoversEveryMachine() {
        XCTAssertTrue(LocalSync(pid: 1, machine: nil, byOperator: false).covers(machine: "main"))
        XCTAssertTrue(LocalSync(pid: 1, machine: "main", byOperator: false).covers(machine: "main"))
        XCTAssertFalse(LocalSync(pid: 1, machine: "edge", byOperator: false).covers(machine: "main"))
    }
}
