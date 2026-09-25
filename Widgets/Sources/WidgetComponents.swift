import MeowModels
import SwiftUI
import WidgetKit

// Building blocks shared by `TunnelWidget` and `RouteModeWidget`.

/// meow's cat, paws up while connected — same art as the app's status glyph.
struct AppMarkImage: View {
    let isConnected: Bool

    var body: some View {
        Image(isConnected ? "AppMarkConnected" : "AppMark")
            .resizable()
            // On a tinted Home Screen, render the cat in the tint rather
            // than as a flat silhouette.
            .widgetAccentedRenderingMode(.accentedDesaturated)
            .scaledToFit()
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}

/// The VPN on/off switch. Only shown once there's a tunnel to start.
struct TunnelSwitch: View {
    let entry: TunnelEntry

    var body: some View {
        if entry.isConfigured {
            Toggle(isOn: entry.isOn, intent: ToggleTunnelIntent()) {
                Text("widget.toggle.label")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Color("Connected"))
        }
    }
}

/// "Connected / Rule-Based Proxy" — the tunnel's state over its route mode.
struct TunnelStatusText: View {
    let entry: TunnelEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.stage.badgeKey)
                .font(.headline)
            Text(entry.detailKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }
}

/// One square button per route mode, the current one filled. Buttons only
/// while connected: the engine holds the mode, so there's nothing to switch
/// when it isn't running.
struct RouteModeButtons: View {
    let entry: TunnelEntry

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RouteMode.allCases) { mode in
                if entry.isConnected {
                    Button(intent: SetRouteModeIntent(mode: mode)) {
                        RouteModeTile(mode: mode, isSelected: mode == entry.routeMode)
                    }
                    .buttonStyle(.plain)
                } else {
                    RouteModeTile(mode: mode, isSelected: mode == entry.routeMode)
                        .opacity(0.4)
                }
            }
        }
    }
}

private struct RouteModeTile: View {
    let mode: RouteMode
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
            .widgetAccentable(isSelected)
            .overlay {
                Image(systemName: mode.symbolName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 44, maxHeight: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(mode.longLabel))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Green when connected, amber mid-transition, red after a failed start.
struct StageDot: View {
    let stage: VpnStage

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(Text(stage.badgeKey))
    }

    private var color: Color {
        switch stage {
        case .idle, .stopped: Color(uiColor: .systemGray3)
        case .preparing, .connecting, .stopping: Color("Warning")
        case .connected: Color("Connected")
        case .error: Color("Danger")
        }
    }
}

extension TunnelEntry {
    /// The route mode — or, before setup, where to go to fix that.
    var detailKey: LocalizedStringKey {
        isConfigured ? routeMode.longLabel : "widget.status.setup"
    }
}

extension VpnStage {
    /// Matches the app's status badge (`GlobalVpnSwitchBar`).
    var badgeKey: LocalizedStringKey {
        switch self {
        case .idle, .stopped, .error: "home.badge.disconnected"
        case .preparing: "home.badge.preparing"
        case .connecting: "home.badge.connecting"
        case .connected: "home.badge.connected"
        case .stopping: "home.badge.disconnecting"
        }
    }
}

extension RouteMode {
    var longLabel: LocalizedStringKey {
        switch self {
        case .rule: "widget.routeMode.rule.long"
        case .all: "widget.routeMode.all.long"
        case .direct: "widget.routeMode.direct.long"
        }
    }

    var symbolName: String {
        switch self {
        case .rule: "arrow.triangle.branch"
        case .all: "globe"
        case .direct: "arrow.right"
        }
    }
}
