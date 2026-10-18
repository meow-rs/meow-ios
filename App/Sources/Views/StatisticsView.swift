import MeowModels
import SwiftUI

/// Utility > Statistics (`StatisticsModel`): the session's start and uptime,
/// then its traffic by network kind and by proxy. Each total expands, on a
/// tap, into its upload and download.
struct StatisticsView: View {
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(\.locale) private var locale
    @State private var model: StatisticsModel

    init(model: StatisticsModel) {
        _model = State(initialValue: model)
    }

    private var startedAt: Date? {
        vpnManager.stage == .connected ? ipcBridge.currentState.startedAt : nil
    }

    var body: some View {
        Group {
            if let startedAt {
                content(startedAt: startedAt)
            } else {
                // The VPN is down, or went down while the page was open.
                ContentUnavailableView(
                    "utility.nav.statistics",
                    systemImage: "chart.pie",
                    description: Text("statistics.offline"),
                )
                .accessibilityIdentifier("statistics.offline")
            }
        }
        .background(AppTheme.screenBackground)
        .navigationTitle("statistics.nav.title")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: vpnManager.stage == .connected) {
            await model.run(connected: vpnManager.stage == .connected)
        }
    }

    private func content(startedAt: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sessionCard(startedAt: startedAt)
                interfacesSection(StatisticsModel.interfaces(in: ipcBridge.currentTraffic, startedAt: startedAt))
                if let policies = model.policies, !policies.isEmpty {
                    policiesSection(policies)
                }
            }
            .padding(16)
            .readableColumn()
        }
        .scrollContentBackground(.hidden)
    }

    private func sessionCard(startedAt: Date) -> some View {
        GlassCard {
            VStack(spacing: 0) {
                InfoRow(
                    label: "statistics.startDate",
                    value: startedAt.formatted(date: .abbreviated, time: .standard),
                )
                Divider()
                // Ticks the uptime every second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    InfoRow(label: "statistics.uptime", value: uptime(from: startedAt, to: context.date))
                        .accessibilityIdentifier("statistics.uptime")
                }
            }
        }
    }

    @ViewBuilder
    private func interfacesSection(_ interfaces: InterfaceTraffic) -> some View {
        SectionHeader("statistics.interfaces")
            .padding(.leading, 4)
            .padding(.top, 4)
        GlassCard {
            VStack(spacing: 0) {
                TrafficRow(
                    title: String(localized: "statistics.wifiEthernet"),
                    totals: interfaces.wifiEthernet,
                    identifier: "statistics.interface.wifiEthernet",
                )
                Divider()
                TrafficRow(
                    title: String(localized: "statistics.cellular"),
                    totals: interfaces.cellular,
                    identifier: "statistics.interface.cellular",
                )
                // A VPN under the VPN, a hotspot over Bluetooth, …: rare
                // enough to only show once it carried something.
                if interfaces.other.total > 0 {
                    Divider()
                    TrafficRow(
                        title: String(localized: "statistics.otherNetworks"),
                        totals: interfaces.other,
                        identifier: "statistics.interface.other",
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func policiesSection(_ policies: [PolicyTraffic]) -> some View {
        SectionHeader("statistics.policies")
            .padding(.leading, 4)
            .padding(.top, 4)
        GlassCard {
            VStack(spacing: 0) {
                ForEach(policies) { policy in
                    if policy.id != policies.first?.id {
                        Divider()
                    }
                    TrafficRow(
                        title: policy.name,
                        totals: policy.totals,
                        identifier: "statistics.policy.\(policy.name.identifierSlug)",
                    )
                }
            }
        }
    }

    /// e.g. "29 hours, 35 minutes, 38 seconds"; units still at zero are left
    /// out up front.
    private func uptime(from start: Date, to end: Date) -> String {
        let seconds = Int(max(0, end.timeIntervalSince(start)))
        let units: Set<Duration.UnitsFormatStyle.Unit> = if seconds >= 3600 {
            [.hours, .minutes, .seconds]
        } else if seconds >= 60 {
            [.minutes, .seconds]
        } else {
            [.seconds]
        }
        return Duration.seconds(seconds).formatted(
            .units(allowed: units, width: .wide, zeroValueUnits: .show(length: 1)).locale(locale),
        )
    }
}

private struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.subheadline)
            Spacer(minLength: 0)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AppTheme.mutedText)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// A total that expands, on a tap, into its upload and download.
private struct TrafficRow: View {
    let title: String
    let totals: ByteTotals
    let identifier: String

    /// A proxy seen for the first time can land above an expanded one; the
    /// ForEach identity keeps the expansion with its name.
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("home.traffic.total \(Self.bytes(totals.total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.mutedText)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)

            if expanded {
                VStack(spacing: 4) {
                    directionRow("home.traffic.upload", bytes: totals.upload)
                        .accessibilityIdentifier("\(identifier).upload")
                    directionRow("home.traffic.download", bytes: totals.download)
                        .accessibilityIdentifier("\(identifier).download")
                }
                .padding(.leading, 16)
                .padding(.trailing, 24)
                .padding(.bottom, 8)
            }
        }
    }

    private func directionRow(_ label: LocalizedStringKey, bytes: Int64) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(Self.bytes(bytes))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(AppTheme.mutedText)
        .accessibilityElement(children: .combine)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}
