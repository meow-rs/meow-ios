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
                        value: uptime(at: context.date),
                    )
                    .accessibilityIdentifier("tv.statistics.uptime")
                }
                TVStatisticCard(
                    title: "tv.statistics.requests",
                    systemImage: "arrow.left.arrow.right",
                    value: traffic.requests.map { Int($0).formatted(.number.locale(locale)) } ?? "\u{2014}",
                )
                .accessibilityIdentifier("tv.statistics.requests")
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                TVStatisticCard(
                    title: "home.traffic.upload",
                    systemImage: "arrow.up",
                    value: Self.bytes(traffic.uploadBytes),
                )
                .accessibilityIdentifier("tv.statistics.upload")
                TVStatisticCard(
                    title: "home.traffic.download",
                    systemImage: "arrow.down",
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

/// One card of `TVStatisticsView`: what it counts, then the number.
private struct TVStatisticCard: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The symbol over a fixed inset rather than a `Label`: the
            // symbols differ in height, and a `Label` row takes the taller
            // of symbol and text, which left the numbers of a row uneven.
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.leading, 50)
                .overlay(alignment: .leading) {
                    Image(systemName: systemImage)
                        .frame(width: 36)
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            // Digits of one width, so a ticking number does not shift.
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
