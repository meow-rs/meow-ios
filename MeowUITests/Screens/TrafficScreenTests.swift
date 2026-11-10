import XCTest

final class TrafficScreenTests: XCTestCase {
    /// A fresh install has no traffic ledger yet (the simulator never runs
    /// the PacketTunnel), so the page shows the usage tiles over an empty
    /// ledger.
    func testEmptyLedgerShowsOnFreshInstall() {
        let meow = MeowApp(resetState: true)
        meow.launch()
        meow.utilityTab.tap()
        meow.app.buttons["utility.nav.traffic"].tap()
        let empty = meow.app.descendants(matching: .any)["traffic.details.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertTrue(meow.app.descendants(matching: .any)["traffic.todayTile"].exists)
        XCTAssertTrue(meow.app.descendants(matching: .any)["traffic.monthTile"].exists)
    }
}
