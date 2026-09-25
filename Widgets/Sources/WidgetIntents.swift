import AppIntents
import MeowModels
import WidgetKit

/// Backs the widgets' VPN switch: connects or disconnects in place, without
/// opening the app. Runs in the widget extension.
struct ToggleTunnelIntent: SetValueIntent {
    static let title: LocalizedStringResource = "widget.intent.toggle.title"
    static let isDiscoverable = false

    @Parameter(title: "widget.intent.toggle.value")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        // Reload even when the switch fails, so it snaps back to the truth.
        defer { WidgetCenter.shared.reloadAllTimelines() }
        try await WidgetTunnel.setRunning(value)
        return .result()
    }
}

/// Backs the widgets' route-mode buttons, which are only live while the
/// tunnel is connected — the engine is what holds the mode.
struct SetRouteModeIntent: AppIntent {
    static let title: LocalizedStringResource = "widget.intent.routeMode.title"
    static let isDiscoverable = false

    /// `RouteMode.rawValue`. A plain string keeps `RouteMode` (declared in
    /// MeowModels) free of an App Intents conformance just for this.
    @Parameter(title: "widget.intent.routeMode.mode")
    var mode: String

    init() {}

    init(mode: RouteMode) {
        self.mode = mode.rawValue
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        defer { WidgetCenter.shared.reloadAllTimelines() }
        guard let target = RouteMode(rawValue: mode) else { return .result() }
        try await EngineModeClient.setMode(target)
        RouteMode.setLastKnown(target, in: AppGroup.defaults)
        return .result()
    }
}
