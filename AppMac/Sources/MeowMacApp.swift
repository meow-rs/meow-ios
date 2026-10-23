import AppKit
import MeowModels
import SwiftData
import SwiftUI

@main
struct MeowMacApp: App {
    @NSApplicationDelegateAdaptor(MeowAppDelegate.self) private var appDelegate
    @State private var appModel: AppModel
    @State private var controller: MacController

    init() {
        let model = AppModel()
        let controller = MacController(appModel: model)
        _appModel = State(initialValue: model)
        _controller = State(initialValue: controller)
        // Bootstrap here rather than in a window's `.task`: in menu-bar-only
        // mode no window opens at launch.
        Task { @MainActor in
            await model.bootstrap()
            controller.start()
        }
    }

    var body: some Scene {
        Window("meow", id: MacWindowID.main) {
            MacRootView()
                .environment(appModel)
                .environment(controller)
        }
        .modelContainer(AppModelContainer.shared.container)
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultLaunchBehavior(controller.presence == .menuBar ? .suppressed : .automatic)
        .commands { MacCommands(controller: controller) }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarPopover()
                .environment(appModel)
                .environment(controller)
                .modelContainer(AppModelContainer.shared.container)
        } label: {
            MenuBarLabel(controller: controller, ipcBridge: appModel.ipcBridge)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environment(appModel)
                .environment(controller)
                .modelContainer(AppModelContainer.shared.container)
        }
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { controller.presence.showsMenuBarExtra },
            set: { inserted in
                // The user can ⌘-drag the item out of the menu bar.
                if !inserted, controller.presence.showsMenuBarExtra {
                    controller.presence = .dock
                }
            },
        )
    }
}

enum MacWindowID {
    static let main = "main"
}

final class MeowAppDelegate: NSObject, NSApplicationDelegate {
    /// The tunnel and the menu bar extra outlive the window.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}

struct MacCommands: Commands {
    let controller: MacController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Connection") {
            Button(controller.isConnected ? "Disconnect" : "Connect") {
                controller.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(controller.isInFlight)

            Divider()

            Picker("Route Mode", selection: routeMode) {
                Text("Rule").tag(RouteModeTag.rule)
                Text("All").tag(RouteModeTag.all)
                Text("Direct").tag(RouteModeTag.direct)
            }
            .disabled(!controller.isConnected)
        }
    }

    private var routeMode: Binding<RouteModeTag> {
        Binding(
            get: { RouteModeTag(controller.routeMode) },
            set: {
                if let mode = $0.mode {
                    controller.setRouteMode(mode)
                }
            },
        )
    }
}

/// `Picker` needs a non-optional selection; `.unknown` stands for "no engine".
private enum RouteModeTag: Hashable {
    case rule, all, direct, unknown

    init(_ mode: RouteMode?) {
        switch mode {
        case .rule: self = .rule
        case .all: self = .all
        case .direct: self = .direct
        case nil: self = .unknown
        }
    }

    var mode: RouteMode? {
        switch self {
        case .rule: .rule
        case .all: .all
        case .direct: .direct
        case .unknown: nil
        }
    }
}
