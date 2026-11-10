import MeowModels
import SwiftUI

/// The running session in four cards, where the subscription controls sit
/// while the tunnel is down: how long it has run, and the requests, upload
/// and download it has carried since it started.
///
/// All four come from the tunnel: the start from its state
/// (`AppIPCBridge.currentState.startedAt`), the rest from the snapshot it
/// publishes twice a second (`AppIPCBridge.currentTraffic`). They start over
/// with the tunnel, as the engine's counters do.
///
/// Cards to read, with nothing to focus: the remote moves between the
/// connect button and the profile list as before.
struct TVStatisticsView: View {
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(\.locale) private var locale

    var body: some View {
        let traffic = sessionTraffic
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                // Ticks the uptime every second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    TVStatisticCard(
                        title: "statistics.uptime",
                        systemImage: "clock",
                        tint: AppTheme.connected,
                        value: uptime(at: context.date),
                    )
                    .accessibilityIdentifier("tv.statistics.uptime")
                }
                TVStatisticCard(
                    title: "tv.statistics.requests",
                    systemImage: "arrow.left.arrow.right",
                    tint: AppTheme.accent,
                    value: traffic.requests.map { Int($0).formatted(.number.locale(locale)) } ?? "\u{2014}",
                )
                .accessibilityIdentifier("tv.statistics.requests")
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                TVStatisticCard(
                    title: "home.traffic.upload",
                    systemImage: "arrow.up",
                    tint: AppTheme.warning,
                    value: Self.bytes(traffic.uploadBytes),
                )
                .accessibilityIdentifier("tv.statistics.upload")
                TVStatisticCard(
                    title: "home.traffic.download",
                    systemImage: "arrow.down",
                    tint: AppTheme.accent,
                    value: Self.bytes(traffic.downloadBytes),
                )
                .accessibilityIdentifier("tv.statistics.download")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The snapshot of this session, zeros until its first one arrives: the
    /// last snapshot of the session before outlives it. A dash for the
    /// requests only from an extension that does not count them.
    private var sessionTraffic: TrafficSnapshot {
        let traffic = ipcBridge.currentTraffic
        if let startedAt = ipcBridge.currentState.startedAt, traffic.timestamp < startedAt {
            return TrafficSnapshot(requests: 0)
        }
        return traffic
    }

    /// "1:05:09" for the first day, then "3d 1h 5m".
    private func uptime(at now: Date) -> String {
        guard let startedAt = ipcBridge.currentState.startedAt else { return "\u{2014}" }
        let duration = Duration.seconds(Int(max(0, now.timeIntervalSince(startedAt))))
        if duration < .seconds(86400) {
            return duration.formatted(.time(pattern: .hourMinuteSecond).locale(locale))
        }
        return duration.formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow).locale(locale),
        )
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}

/// One card of `TVStatisticsView`: its symbol in a tinted disc, then what
/// it counts over the number. The iPhone's traffic tiles in the brand palette
/// (`AppTheme`), with their tints: green for time, orange for upload, blue
/// for the rest.
private struct TVStatisticCard: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let value: String

    var body: some View {
        HStack(spacing: 18) {
            // A disc of one size whatever the symbol: the symbols differ in
            // height, and sized by their own bounds the cards of a row came
            // out uneven.
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(tint.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // Digits of one width, so a ticking number does not shift.
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(AppTheme.panelRaised, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
