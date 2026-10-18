import XCTest

final class UtilityScreenTests: XCTestCase {
    func testUtilityHubShowsTrafficStatisticsLogsAndDnsEntries() {
        let meow = MeowApp(resetState: true)
        meow.launch()
        meow.utilityTab.tap()

        XCTAssertTrue(meow.app.navigationBars["Utility"].waitForExistence(timeout: 5))
        XCTAssertTrue(meow.app.buttons["utility.nav.traffic"].waitForExistence(timeout: 5))
        XCTAssertTrue(meow.app.buttons["utility.nav.statistics"].exists)
        XCTAssertTrue(meow.app.buttons["utility.nav.logs"].exists)
        XCTAssertTrue(meow.app.buttons["utility.nav.dns"].exists)
    }

    func testDnsPanelShowsMockResultsInSimulator() {
        let meow = MeowApp(resetState: true)
        meow.launch()
        meow.utilityTab.tap()
        meow.app.buttons["utility.nav.dns"].tap()

        XCTAssertTrue(meow.app.navigationBars["DNS (4)"].waitForExistence(timeout: 5))
        XCTAssertTrue(meow.app.descendants(matching: .any)["dns.row.github-com"].waitForExistence(timeout: 5))
    }
}
