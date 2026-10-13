import SwiftUI

/// A proxy's detail page, opened by long-pressing a node on Proxy Groups:
/// its type and UDP support, then one row per test (`ProxyDetailModel`).
struct ProxyDetailView: View {
    @Environment(VpnManager.self) private var vpnManager
    @State private var model: ProxyDetailModel

    init(model: ProxyDetailModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                GlassCard {
                    VStack(spacing: 0) {
                        infoRow("proxyDetail.type", value: model.type.flatMap { $0.isEmpty ? nil : $0 })
                        Divider()
                        infoRow("proxyDetail.udp", value: udpValue)
                    }
                }
                if !model.connected {
                    Text("proxyDetail.connectHint")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                }
                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(ProxyProbe.allCases, id: \.self) { probe in
                            if probe != ProxyProbe.allCases.first {
                                Divider()
                            }
                            ProbeRow(
                                probe: probe,
                                state: model.state(of: probe),
                                connected: model.connected,
                                // No relay, nothing to measure: say so rather
                                // than offer a test bound to fail.
                                noUDP: probe.needsUDP && model.udp == false,
                                onTest: { model.test(probe) },
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(AppTheme.screenBackground)
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: vpnManager.stage == .connected) {
            await model.setConnected(vpnManager.stage == .connected)
        }
        // Leaving the page ends its tests, in the extension too.
        .onDisappear { model.stopAll() }
    }

    private var udpValue: String? {
        model.udp.map { $0 ? String(localized: "proxyDetail.supported") : String(localized: "proxyDetail.unsupported") }
    }

    private func infoRow(_ label: LocalizedStringKey, value: String?) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value ?? ProbeRow.placeholder)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct ProbeRow: View {
    static let placeholder = "—"

    @Environment(\.locale) private var locale

    let probe: ProxyProbe
    let state: ProbeState
    let connected: Bool
    let noUDP: Bool
    let onTest: () -> Void

    private var enabled: Bool {
        connected && !noUDP && state != .running
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(probe.title)
                    .font(.subheadline)
                value
            }
            Spacer(minLength: 8)
            if state == .running {
                // The button's footprint, so the row does not shift.
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Button("proxyDetail.test", action: onTest)
                    .buttonStyle(.borderless)
                    .disabled(!enabled)
                    .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if enabled {
                onTest()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("proxyDetail.probe.\(probe)")
    }

    @ViewBuilder
    private var value: some View {
        if noUDP {
            valueLine(String(localized: "proxyDetail.udpUnsupported"), AppTheme.mutedText)
        } else {
            switch state {
            case let .done(result):
                resultLines(result)
            case let .failed(reason, detail):
                failureLines(reason, detail: detail)
            case .running:
                valueLine(String(localized: "proxyDetail.testing"), AppTheme.mutedText)
            case .idle:
                valueLine(
                    connected ? String(localized: "proxyDetail.tapToTest") : Self.placeholder,
                    AppTheme.mutedText,
                )
            }
        }
    }

    @ViewBuilder
    private func resultLines(_ result: ProbeResult) -> some View {
        switch result {
        case let .latency(ms):
            valueLine("\(ms) ms", Self.latencyTint(ms))
        case let .exit(exitIP):
            valueLine(exitIP.ip, .primary)
            let details = [
                exitIP.flagEmoji,
                exitIP.countryName(locale: locale),
                exitIP.networkLabel.map { "· \($0)" },
            ].compactMap(\.self).joined(separator: " ")
            if !details.isEmpty {
                detailLine(details)
            }
        case let .nat(nat):
            valueLine(String(localized: nat.natClass.label), .primary)
            if nat.sourceHidden {
                detailLine(String(localized: "proxyDetail.nat.sourceHidden"))
            } else if let mapped = nat.mappedAddress {
                detailLine(mapped)
            }
        case let .bandwidth(throughput):
            valueLine(BitRate.format(throughput.bitsPerSecond), .primary)
            detailLine(
                ByteCountFormatter.string(fromByteCount: Int64(throughput.bitsPerSecond / 8), countStyle: .binary)
                    + "/s",
            )
        }
    }

    @ViewBuilder
    private func failureLines(_ reason: ProbeFailure, detail: String?) -> some View {
        switch reason {
        case .timedOut:
            valueLine(String(localized: "proxyDetail.timeout"), AppTheme.danger)
        case .udpUnsupported:
            valueLine(String(localized: "proxyDetail.udpUnsupported"), AppTheme.mutedText)
        case .failed:
            valueLine(String(localized: "proxyDetail.failed"), AppTheme.danger)
            if let detail {
                detailLine(detail)
            }
        }
    }

    private func valueLine(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(color)
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AppTheme.mutedText)
            .lineLimit(2)
    }

    /// The Proxy Groups delay badge's colors.
    private static func latencyTint(_ ms: Int) -> Color {
        switch ms {
        case ..<200: AppTheme.connected
        case 200 ..< 500: AppTheme.warning
        default: AppTheme.danger
        }
    }
}

extension ProxyProbe {
    var title: LocalizedStringResource {
        switch self {
        case .tcpLatency: "proxyDetail.tcpLatency"
        case .udpLatency: "proxyDetail.udpLatency"
        case .exitIP: "proxyDetail.exitIP"
        case .nat: "proxyDetail.nat"
        case .download: "proxyDetail.download"
        case .upload: "proxyDetail.upload"
        }
    }
}

extension NatClass {
    var label: LocalizedStringResource {
        switch self {
        case .fullCone: "proxyDetail.nat.fullCone"
        case .restrictedCone: "proxyDetail.nat.restrictedCone"
        case .portRestrictedCone: "proxyDetail.nat.portRestrictedCone"
        case .cone: "proxyDetail.nat.cone"
        case .symmetric: "proxyDetail.nat.symmetric"
        case .unknown: "proxyDetail.nat.unknown"
        }
    }
}

enum BitRate {
    private static let units = ["bps", "Kbps", "Mbps", "Gbps"]

    /// `85.3 Mbps`, `940 Kbps`: decimal steps, as link speeds are quoted.
    static func format(_ bitsPerSecond: Double) -> String {
        var amount = abs(bitsPerSecond)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        // `String(format:)` without a locale always writes a `.` decimal point.
        return String(format: unit == 0 || amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }
}
