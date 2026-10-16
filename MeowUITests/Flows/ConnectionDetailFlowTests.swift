import XCTest

/// Flow: tap a row on Connections to open its detail page. `-ScreenshotDemo`
/// launches the mock tunnel connected, and the simulator's canned engine
/// lists three connections (`MeowAPI.mockConnections()`).
final class ConnectionDetailFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func openConnection(_ id: String) -> MeowApp {
        let meow = MeowApp()
        meow.app.launchArguments.append("-ScreenshotDemo")
        meow.launch()
        XCTAssertTrue(meow.subscriptionsTab.waitForExistence(timeout: 5))
        meow.subscriptionsTab.tap()
        // At compact width the Engine section sits below the configs.
        let nav = meow.app.descendants(matching: .any)["home.nav.connections"]
        for _ in 0 ..< 6 where !(nav.exists && nav.isHittable) {
            meow.app.swipeUp()
        }
        XCTAssertTrue(nav.waitForExistence(timeout: 5))
        nav.tap()

        let row = meow.app.descendants(matching: .any)["connections.row.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        return meow
    }

    private func field(_ meow: MeowApp, _ id: String) -> XCUIElement {
        meow.app.descendants(matching: .any)["connectionDetail.\(id)"]
    }

    /// Waits for the field `id` to read `text`. A query rather than
    /// `waitForExpectations`, which Swift 6 rejects here: it sends the
    /// non-Sendable test case to the main actor.
    private func waitForField(_ meow: MeowApp, _ id: String, containing text: String) -> Bool {
        meow.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "connectionDetail.\(id)", text),
        ).firstMatch.waitForExistence(timeout: 10)
    }

    func testDetailShowsTheMatchedRuleAndOpensRulesOnIt() {
        let meow = openConnection("sim-2")
        XCTAssertTrue(waitForField(meow, "status", containing: "Active"))
        XCTAssertTrue(waitForField(meow, "remoteIP", containing: "140.82.112.4"))

        // mockRules()[1] is `DOMAIN-SUFFIX,github.com,Proxy`.
        XCTAssertTrue(waitForField(meow, "rule", containing: "Rule #2"))
        field(meow, "rule").tap()
        XCTAssertTrue(meow.app.descendants(matching: .any)["rules.row.1"].waitForExistence(timeout: 5))
    }

    func testDirectFlowWithoutAnIPFindsItInTheDNSCache() {
        let meow = openConnection("sim-3")
        // mockDnsResults' answer for apple.com.
        XCTAssertTrue(waitForField(meow, "remoteIP", containing: "17.253.144.10"))
        XCTAssertTrue(field(meow, "remoteIP").label.contains("From the DNS cache"))
        XCTAssertTrue(field(meow, "dnsMode").label.contains("fake-ip"))
    }

    func testCloseLivesInTheDetailMenu() {
        let meow = openConnection("sim-1")
        let menu = meow.app.descendants(matching: .any)["connectionDetail.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let close = meow.app.descendants(matching: .any)["connectionDetail.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        XCTAssertTrue(waitForField(meow, "status", containing: "Closed"))
        XCTAssertFalse(menu.exists)
    }
}
