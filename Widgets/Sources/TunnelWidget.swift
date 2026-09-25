import SwiftUI
import WidgetKit

/// The VPN switch over the tunnel's status; the medium size adds the
/// route-mode buttons.
struct TunnelWidget: Widget {
    static let kind = "com.tangzixiang.meow.widget.tunnel"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TunnelTimelineProvider()) { entry in
            TunnelWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("widget.tunnel.name")
        .description("widget.tunnel.description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TunnelWidgetView: View {
    let entry: TunnelEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                AppMarkImage(isConnected: entry.isConnected)
                Spacer(minLength: 8)
                TunnelSwitch(entry: entry)
            }
            Spacer(minLength: 8)
            HStack(alignment: .bottom, spacing: 12) {
                TunnelStatusText(entry: entry)
                if family == .systemMedium {
                    Spacer(minLength: 0)
                    RouteModeButtons(entry: entry)
                }
            }
        }
    }
}

#Preview(as: .systemSmall) {
    TunnelWidget()
} timeline: {
    TunnelEntry.placeholder
    TunnelEntry(date: .now, stage: .stopped, routeMode: .rule, isConfigured: true)
    TunnelEntry(date: .now, stage: .idle, routeMode: .rule, isConfigured: false)
}

#Preview(as: .systemMedium) {
    TunnelWidget()
} timeline: {
    TunnelEntry.placeholder
    TunnelEntry(date: .now, stage: .stopped, routeMode: .all, isConfigured: true)
}
