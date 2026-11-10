import MeowModels
import SwiftData
import SwiftUI

/// Utility > Traffic: data usage today and this month, then the engine's
/// traffic ledger (`TrafficLedgerModel`) for a period by host, policy or
/// network, where a row opens the ledger narrowed to it. A usage tile picks
/// its period below. The top bar clears the whole ledger; it lives on this
/// page only, as a narrowed page offering it would read as clearing that
/// row.
struct TrafficView: View {
    @Query(sort: \DailyTraffic.date, order: .reverse) private var daily: [DailyTraffic]
    @State private var model = TrafficLedgerModel()
    @State private var opened: TrafficDestination?
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("traffic.dataUsage")
                    .padding(.leading, 4)
                usageTiles
                SectionHeader("traffic.details.title")
                    .padding(.leading, 4)
                    .padding(.top, 8)
                TrafficLedgerSection(model: model) { opened = $0 }
            }
            .padding(16)
            .readableColumn()
        }
        .background(AppTheme.screenBackground)
        .scrollContentBackground(.hidden)
        .navigationTitle("traffic.nav.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Label("traffic.details.clear", systemImage: "trash")
                }
                .accessibilityIdentifier("traffic.details.clear")
            }
        }
        .alert("traffic.details.clear", isPresented: $confirmingClear) {
            Button("common.delete", role: .destructive) {
                Task { await model.clear() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("traffic.details.clearConfirm")
        }
        .alert("traffic.details.clear", isPresented: clearFailed, presenting: model.clearError) { _ in
            Button("common.ok") {}
        } message: { error in
            Text("traffic.details.clearFailed \(error)")
        }
        .task(id: model.query) { await model.run() }
        .navigationDestination(item: $opened) { TrafficDetailsView(destination: $0) }
    }

    private var clearFailed: Binding<Bool> {
        Binding(
            get: { model.clearError != nil },
            set: {
                if !$0 {
                    model.clearError = nil
                }
            },
        )
    }

    /// The two tiles stand as tall as the taller one.
    private var usageTiles: some View {
        HStack(spacing: 12) {
            UsageTile(
                title: "traffic.tile.today",
                tx: todayTotals.tx,
                rx: todayTotals.rx,
                identifier: "traffic.todayTile",
            ) { model.period = .today }
            UsageTile(
                title: "traffic.tile.thisMonth",
                tx: monthTotals.tx,
                rx: monthTotals.rx,
                identifier: "traffic.monthTile",
            ) { model.period = .thisMonth }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var todayTotals: (tx: Int64, rx: Int64) {
        let key = DailyTraffic.key(for: .now)
        guard let entry = daily.first(where: { $0.date == key }) else { return (0, 0) }
        return (entry.txBytes, entry.rxBytes)
    }

    private var monthTotals: (tx: Int64, rx: Int64) {
        let prefix = DailyTraffic.key(for: .now).prefix(7) // yyyy-MM
        return daily
            .filter { $0.date.hasPrefix(prefix) }
            .reduce((Int64(0), Int64(0))) { ($0.0 + $1.txBytes, $0.1 + $1.rxBytes) }
    }
}

/// A period's data usage: its total, then downloads and uploads a line
/// each, so a value never breaks between its number and its unit. A tap
/// shows the period's traffic details below.
private struct UsageTile: View {
    let title: LocalizedStringKey
    let tx: Int64
    let rx: Int64
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    Text(TrafficBytes.text(tx + rx))
                        .font(.headline.monospacedDigit())
                        .padding(.bottom, 2)
                    direction("home.traffic.download", bytes: rx, systemImage: "arrow.down", tint: AppTheme.accent)
                        .accessibilityIdentifier("\(identifier).rx")
                    direction("home.traffic.upload", bytes: tx, systemImage: "arrow.up", tint: AppTheme.warning)
                        .accessibilityIdentifier("\(identifier).tx")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }

    private func direction(_ label: LocalizedStringKey, bytes: Int64, systemImage: String, tint: Color) -> some View {
        Label {
            Text(TrafficBytes.text(bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(TrafficBytes.text(bytes)))
    }
}
