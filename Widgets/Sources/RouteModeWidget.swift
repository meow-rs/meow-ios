import SwiftUI
import WidgetKit

/// The route-mode buttons on their own, over the current mode and a
/// connection dot — or, on the Lock Screen, under the current mode.
struct RouteModeWidget: Widget {
    static let kind = "com.tangzixiang.meow.widget.routeMode"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TunnelTimelineProvider()) { entry in
            RouteModeWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("home.routeMode.title")
        .description("widget.routeMode.description")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

private struct RouteModeWidgetView: View {
    let entry: TunnelEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryRectangular {
            RouteModeRectangularView(entry: entry)
        } else {
            homeScreen
        }
    }

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home.routeMode.title")
                .font(.headline)
                .foregroundStyle(Color("Ginger"))
                .widgetAccentable()
                .lineLimit(1)
            RouteModeButtons(entry: entry)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(entry.detailKey)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                StageDot(stage: entry.stage)
            }
        }
    }
}

#Preview(as: .systemSmall) {
    RouteModeWidget()
} timeline: {
    TunnelEntry.placeholder
    TunnelEntry(date: .now, stage: .connected, routeMode: .direct, isConfigured: true)
    TunnelEntry(date: .now, stage: .stopped, routeMode: .rule, isConfigured: true)
}

#Preview(as: .accessoryRectangular) {
    RouteModeWidget()
} timeline: {
    TunnelEntry.placeholder
    TunnelEntry(date: .now, stage: .stopped, routeMode: .all, isConfigured: true)
}
