import SwiftData
import SwiftUI

@main
struct MeowApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(appModel.vpnManager)
                .environment(appModel.meowAPI)
                .environment(appModel.subscriptionService)
                .environment(appModel.ipcBridge)
                .environment(appModel.utilityTrafficChart)
                .environment(appModel.utilityLogs)
                .environment(appModel.iCloudRelayStore)
                .task { await appModel.bootstrap() }
        }
        .modelContainer(AppModelContainer.shared.container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                WidgetReloader.appDidBecomeActive()
            }
        }
    }
}
