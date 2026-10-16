import XCTest

/// Flow: long-press a node on Proxy Groups to open its detail page, and the
/// tab's tips sheet. `-ScreenshotDemo` launches the mock tunnel connected
/// with the first group ("Auto") expanded, and the simulator's canned engine
/// answers every test.
final class ProxyDetailFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchConnected() -> MeowApp {
        let meow = MeowApp()
        meow.app.launchArguments.append("-ScreenshotDemo")
        meow.launch()
        XCTAssertTrue(meow.proxyGroupsTab.waitForExistence(timeout: 5))
        meow.proxyGroupsTab.tap()
        return meow
    }

    func testLongPressOpensTheDetailPageAndRunsATest() {
        let meow = launchConnected()
        let node = meow.app.descendants(matching: .any)["home.proxy.auto.tokyo-01"]
        XCTAssertTrue(node.waitForExistence(timeout: 10))
        node.press(forDuration: 1.0)

        XCTAssertTrue(meow.app.navigationBars["Tokyo 01"].waitForExistence(timeout: 5))
        let tcp = meow.app.descendants(matching: .any)["proxyDetail.probe.tcpLatency"]
        XCTAssertTrue(tcp.waitForExistence(timeout: 5))
        tcp.tap()
        // The mock engine's delay for Tokyo 01. A query rather than
        // `waitForExpectations`, which Swift 6 rejects here: it sends the
        // non-Sendable test case to the main actor.
        let measured = meow.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "proxyDetail.probe.tcpLatency", "76 ms"),
        ).firstMatch
        XCTAssertTrue(measured.waitForExistence(timeout: 10))
    }

    func testTipsSheetExplainsTheLongPress() {
        let meow = launchConnected()
        let tips = meow.app.buttons["proxyGroups.tipsButton"]
        XCTAssertTrue(tips.waitForExistence(timeout: 5))
        tips.tap()

        let longPress = meow.app.staticTexts["Long-press a node to open its details and test it on its own:"]
        XCTAssertTrue(longPress.waitForExistence(timeout: 5))
        // The detail page's own row titles.
        XCTAssertTrue(meow.app.staticTexts["NAT Type"].exists)
        XCTAssertTrue(meow.app.staticTexts["Tests need the VPN connected."].exists)
    }
}
