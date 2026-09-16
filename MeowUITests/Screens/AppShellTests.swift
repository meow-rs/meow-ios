import XCTest

final class AppShellTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testGlobalVpnTogglePersistsAcrossPrimaryTabs() {
        let meow = MeowApp()
        meow.launch()

        XCTAssertTrue(meow.home.vpnToggle.waitForExistence(timeout: 5))

        meow.subscriptionsTab.tap()
        XCTAssertTrue(meow.home.vpnToggle.exists)

        meow.proxyGroupsTab.tap()
        XCTAssertTrue(meow.home.vpnToggle.exists)

        meow.utilityTab.tap()
        XCTAssertTrue(meow.home.vpnToggle.exists)
    }

    func testSubscriptionsIsDefaultHomeTab() {
        let meow = MeowApp()
        meow.launch()

        XCTAssertTrue(meow.app.navigationBars["Configs"].waitForExistence(timeout: 5))
        XCTAssertFalse(meow.app.tabBars.buttons["Home"].exists)
    }

    func testEmptySubscriptionsOffersAddActions() {
        let meow = MeowApp()
        meow.launch()

        let addFromURL = meow.app.buttons["subscriptions.empty.addFromURL"]
        XCTAssertTrue(addFromURL.waitForExistence(timeout: 5))
        XCTAssertTrue(meow.app.buttons["subscriptions.empty.importFromFile"].exists)

        addFromURL.tap()
        XCTAssertTrue(meow.app.navigationBars["Add Config"].waitForExistence(timeout: 5))
    }

    /// Regular-width shell (iPad today, the iPhone Duo inner display once
    /// its simulator ships): the sidebar-adaptable tab bar still exposes all
    /// four tabs and the global VPN toggle stays put while switching.
    func testRegularWidthShellKeepsTabsAndGlobalToggle() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "regular-width shell only exists on iPad-class displays",
        )
        let meow = MeowApp()
        meow.launch()

        XCTAssertTrue(meow.home.vpnToggle.waitForExistence(timeout: 5))
        for tab in [meow.proxyGroupsTab, meow.utilityTab, meow.settingsTab, meow.subscriptionsTab] {
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            tab.tap()
            XCTAssertTrue(meow.home.vpnToggle.exists)
        }
        XCTAssertTrue(meow.app.navigationBars["Configs"].waitForExistence(timeout: 5))
    }

    func testProxyGroupsIsTopLevelTab() {
        let meow = MeowApp()
        meow.launch()

        XCTAssertTrue(meow.proxyGroupsTab.waitForExistence(timeout: 5))
        meow.proxyGroupsTab.tap()
        XCTAssertTrue(meow.app.navigationBars["Proxy Groups"].waitForExistence(timeout: 5))
    }
}
