import XCTest

/// Flow: Utility > Statistics. `-ScreenshotDemo` launches the mock tunnel
/// connected an hour ago, with the simulator's canned traffic split and
/// per-proxy totals; a fresh launch is disconnected.
final class StatisticsFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func openStatistics(_ meow: MeowApp) {
        meow.launch()
        XCTAssertTrue(meow.utilityTab.waitForExistence(timeout: 5))
        meow.utilityTab.tap()
        let row = meow.app.buttons["utility.nav.statistics"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(meow.app.navigationBars["Statistics"].waitForExistence(timeout: 5))
    }

    func testDisconnectedShowsTheOfflineHint() {
        let meow = MeowApp(resetState: true)
        openStatistics(meow)
        let offline = meow.app.descendants(matching: .any)["statistics.offline"]
        XCTAssertTrue(offline.waitForExistence(timeout: 5))
    }

    func testConnectedShowsTheSessionByNetworkAndByProxy() {
        let meow = MeowApp()
        meow.app.launchArguments.append("-ScreenshotDemo")
        openStatistics(meow)

        // Connected an hour ago: the hours lead.
        let uptime = meow.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "statistics.uptime", "hour"),
        ).firstMatch
        XCTAssertTrue(uptime.waitForExistence(timeout: 5))
        XCTAssertTrue(meow.app.buttons["statistics.interface.wifiEthernet"].exists)
        XCTAssertTrue(meow.app.buttons["statistics.interface.cellular"].exists)
        // Nothing went out on another kind of network.
        XCTAssertFalse(meow.app.buttons["statistics.interface.other"].exists)

        let tokyo = meow.app.buttons["statistics.policy.tokyo-01"]
        XCTAssertTrue(tokyo.waitForExistence(timeout: 5))
        XCTAssertTrue(meow.app.buttons["statistics.policy.direct"].exists)
        // A proxy that carried nothing is left out.
        XCTAssertFalse(meow.app.buttons["statistics.policy.reject"].exists)

        tokyo.tap()
        let upload = meow.app.descendants(matching: .any)["statistics.policy.tokyo-01.upload"]
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
    }
}
