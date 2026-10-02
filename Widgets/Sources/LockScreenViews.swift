import MeowModels
import SwiftUI
import WidgetKit

// Lock Screen (accessory) layouts. These render in a single tint, so the
// state is carried by SF Symbols and fill rather than colour.

/// Circular: a shield showing the tunnel state; tapping it turns the VPN on
/// or off.
struct TunnelCircularView: View {
    let entry: TunnelEntry

    var body: some View {
        TunnelTapTarget(entry: entry) {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: entry.stage.lockScreenSymbol)
                        .font(.title3.weight(.semibold))
                        .widgetAccentable()
                    Text("widget.toggle.label")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
        }
        .accessibilityLabel(Text(entry.stage.badgeKey))
    }
}

/// Rectangular: "meow", the tunnel state and its route mode, with the
/// shield as the on/off button.
struct TunnelRectangularView: View {
    let entry: TunnelEntry

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "meow")
                    .font(.headline)
                    .widgetAccentable()
                Text(entry.stage.badgeKey)
                    .font(.subheadline)
                Text(entry.detailKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            TunnelTapTarget(entry: entry) {
                Image(systemName: entry.stage.lockScreenSymbol)
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(AccessoryWidgetBackground().clipShape(Circle()))
                    .widgetAccentable()
            }
            .accessibilityLabel(Text("widget.toggle.label"))
        }
    }
}

/// Inline (the line above the clock). WidgetKit doesn't make inline widgets
/// interactive, so this one only reports.
struct TunnelInlineView: View {
    let entry: TunnelEntry

    var body: some View {
        Label {
            Text(entry.stage.badgeKey)
        } icon: {
            Image(systemName: entry.stage.lockScreenSymbol)
        }
    }
}

/// Rectangular route-mode picker: the current mode over one button per mode.
struct RouteModeRectangularView: View {
    let entry: TunnelEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.detailKey)
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                ForEach(RouteMode.allCases) { mode in
                    if entry.isConnected {
                        Button(intent: SetRouteModeIntent(mode: mode)) {
                            AccessoryModeTile(mode: mode, isSelected: mode == entry.routeMode)
                        }
                        .buttonStyle(.plain)
                    } else {
                        AccessoryModeTile(mode: mode, isSelected: mode == entry.routeMode)
                            .opacity(0.5)
                    }
                }
            }
        }
    }
}

/// Starts or stops the tunnel on tap. Before setup there's nothing to start,
/// so the content stays inert and a tap just opens the app.
private struct TunnelTapTarget<Content: View>: View {
    let entry: TunnelEntry
    @ViewBuilder let content: Content

    var body: some View {
        if entry.isConfigured {
            Button(intent: ToggleTunnelIntent(value: !entry.isOn)) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// A mode button for a single-tint Lock Screen: the selected one is a
/// solid capsule with the symbol cut out of it, the rest are outlines.
private struct AccessoryModeTile: View {
    let mode: RouteMode
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Capsule()
                    .fill(.primary)
                    .widgetAccentable()
                Image(systemName: mode.symbolName)
                    .font(.footnote.weight(.bold))
                    .blendMode(.destinationOut)
            } else {
                Capsule()
                    .strokeBorder(.secondary, lineWidth: 1)
                Image(systemName: mode.symbolName)
                    .font(.footnote.weight(.semibold))
            }
        }
        .compositingGroup()
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(mode.longLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension VpnStage {
    var lockScreenSymbol: String {
        switch self {
        case .connected: "checkmark.shield.fill"
        case .preparing, .connecting, .stopping: "shield.lefthalf.filled"
        case .error: "exclamationmark.shield"
        case .idle, .stopped: "shield.slash"
        }
    }
}
