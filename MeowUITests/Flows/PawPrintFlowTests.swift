import XCTest

/// Flow: Utility > Paw Print. The simulator runs no PacketTunnel, so no
/// engine ever writes the logbook: the page is empty, and so is every event
/// picked from the top bar's menu.
final class PawPrintFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func openPawPrint(_ meow: MeowApp) {
        meow.launch()
        XCTAssertTrue(meow.utilityTab.waitForExistence(timeout: 5))
        meow.utilityTab.tap()
        let row = meow.app.buttons["utility.nav.pawPrint"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(meow.app.navigationBars["Paw Print"].waitForExistence(timeout: 5))
    }

    func testAnEmptyLogbookSaysWhatItKeeps() {
        let meow = MeowApp(resetState: true)
        openPawPrint(meow)
        XCTAssertTrue(meow.app.descendants(matching: .any)["logbook.empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(meow.app.staticTexts["Nothing recorded yet"].exists)
    }

    func testPickingAnEventShowsOnlyThatEvent() {
        let meow = MeowApp(resetState: true)
        openPawPrint(meow)

        let filter = meow.app.descendants(matching: .any)["logbook.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        let started = meow.app.buttons["Engine Started"]
        XCTAssertTrue(started.waitForExistence(timeout: 5))
        started.tap()

        XCTAssertTrue(meow.app.staticTexts["No “Engine Started” events yet"].waitForExistence(timeout: 5))
    }
}
