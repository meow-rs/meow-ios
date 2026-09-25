import Foundation
import MeowModels
import WidgetKit

/// What every meow widget shows: where the tunnel is and how it routes.
struct TunnelEntry: TimelineEntry {
    let date: Date
    let stage: VpnStage
    let routeMode: RouteMode
    /// False until the app has saved its VPN configuration and the user has
    /// picked a profile — until then the switch has nothing to start.
    let isConfigured: Bool

    /// Switch position. On while connecting too, so the switch doesn't flick
    /// back off between the tap and the tunnel coming up.
    var isOn: Bool {
        stage.isActive
    }

    var isConnected: Bool {
        stage == .connected
    }

    static let placeholder = TunnelEntry(date: .now, stage: .connected, routeMode: .rule, isConfigured: true)

    @MainActor
    static func load() async -> TunnelEntry {
        let status = await WidgetTunnel.status()
        let mode = await routeMode(for: status.stage)
        return TunnelEntry(date: .now, stage: status.stage, routeMode: mode, isConfigured: status.isConfigured)
    }

    /// The engine holds the route mode only while it runs, and every start
    /// resets it to the profile's `mode:`. So ask the engine while connected,
    /// and otherwise show the mode the next start will use.
    @MainActor
    private static func routeMode(for stage: VpnStage) async -> RouteMode {
        let defaults = AppGroup.defaults
        switch stage {
        case .connected:
            // The REST API binds shortly after the tunnel reports connected,
            // and a switch-on reload lands right at that edge — retry briefly.
            for attempt in 1 ... 4 {
                if let live = try? await EngineModeClient.fetchMode() {
                    RouteMode.setLastKnown(live, in: defaults)
                    return live
                }
                if attempt < 4 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            return RouteMode.lastKnown(in: defaults) ?? configuredMode()
        case .idle, .stopped, .error:
            // Covers stops the app wasn't running to see.
            RouteMode.clearLastKnown(in: defaults)
            return configuredMode()
        case .preparing, .connecting, .stopping:
            // Mid-transition, or reasserting with the engine still up.
            return RouteMode.lastKnown(in: defaults) ?? configuredMode()
        }
    }

    private static func configuredMode() -> RouteMode {
        RouteMode.configured(inYAML: (try? String(contentsOf: AppGroup.configURL, encoding: .utf8)) ?? "")
    }
}

struct TunnelTimelineProvider: TimelineProvider {
    /// Timelines are refreshed on demand — by the app when the tunnel or
    /// route mode changes, and by the widgets' own intents. This interval
    /// only catches changes neither saw, such as the tunnel being stopped
    /// from Settings while the app isn't running. WidgetKit throttles
    /// widgets that ask for much more than a few dozen reloads a day.
    private static let refreshInterval: TimeInterval = 30 * 60

    func placeholder(in _: Context) -> TunnelEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TunnelEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        let completion = UncheckedSendable(completion)
        Task { @MainActor in
            await completion.value(TunnelEntry.load())
        }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TunnelEntry>) -> Void) {
        let completion = UncheckedSendable(completion)
        Task { @MainActor in
            let entry = await TunnelEntry.load()
            let next = entry.date.addingTimeInterval(Self.refreshInterval)
            completion.value(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

/// Carries WidgetKit's completion handlers into a `Task`. They're declared
/// without `@Sendable`, but WidgetKit accepts calls from any thread.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
