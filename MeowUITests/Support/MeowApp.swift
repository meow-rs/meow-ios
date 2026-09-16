import XCTest

/// Launch helpers for UI tests. Wraps `XCUIApplication` with the standard
/// set of launch arguments so every test suite starts from a known state.
struct MeowApp {
    let app: XCUIApplication

    init(resetState: Bool = true, stubbedRESTBase: String? = nil) {
        app = XCUIApplication()
        app.launchArguments.append("-UITests")
        if resetState {
            app.launchArguments.append("-ResetState")
        }
        if let base = stubbedRESTBase {
            app.launchArguments.append(contentsOf: ["-StubURL", base])
        }
    }

    func launch() {
        app.launch()
    }

    /// Tab navigation
    var subscriptionsTab: XCUIElement {
        app.tab("Configs")
    }

    var proxyGroupsTab: XCUIElement {
        app.tab("Proxy Groups")
    }

    var utilityTab: XCUIElement {
        app.tab("Utility")
    }

    var settingsTab: XCUIElement {
        app.tab("Settings")
    }

    /// Page objects — thin wrappers; fill in as views land.
    var home: HomeScreen {
        HomeScreen(app: app)
    }

    var subscriptions: SubscriptionsScreen {
        SubscriptionsScreen(app: app)
    }
}

extension XCUIApplication {
    /// A top-level tab by its label. At compact width the tab bar is a
    /// classic `TabBar` of buttons; at regular width (iPad, and the iPhone
    /// Duo inner display) iOS 26's floating tab bar exposes its items as
    /// cells with no `TabBar` ancestor, so match on label and type instead
    /// of on the container.
    func tab(_ label: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)",
            label,
            XCUIElement.ElementType.button.rawValue,
            XCUIElement.ElementType.cell.rawValue,
        )
        return descendants(matching: .any).matching(predicate).firstMatch
    }
}

struct HomeScreen {
    let app: XCUIApplication
    var vpnToggle: XCUIElement {
        app.buttons["vpn.toggle"]
    }

    var statusLabel: XCUIElement {
        app.staticTexts["vpn.status"]
    }

    var uploadRate: XCUIElement {
        app.staticTexts["traffic.uploadRate"]
    }

    var downloadRate: XCUIElement {
        app.staticTexts["traffic.downloadRate"]
    }

    var routeModePicker: XCUIElement {
        app.buttons["routeMode.picker"]
    }
}

struct SubscriptionsScreen {
    let app: XCUIApplication
    var addButton: XCUIElement {
        app.navigationBars.buttons["subscriptions.add"]
    }

    var nameField: XCUIElement {
        app.textFields["subscription.name"]
    }

    var urlField: XCUIElement {
        app.textFields["subscription.url"]
    }

    var submitButton: XCUIElement {
        app.buttons["subscription.submit"]
    }

    func row(named name: String) -> XCUIElement {
        app.cells["subscription.row.\(name)"]
    }
}
