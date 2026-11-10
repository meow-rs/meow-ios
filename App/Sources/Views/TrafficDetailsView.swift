import MeowModels
import SwiftUI

/// A row's page: the ledger narrowed to it, in the period and grouping of
/// the page it was opened from.
struct TrafficDestination: Hashable, Identifiable {
    let filter: TrafficFilter
    let period: TrafficPeriod
    let group: TrafficGroup
    /// The row's name as that page showed it.
    let title: String

    var id: Self {
        self
    }
}

/// The traffic ledger narrowed to a row picked on the Traffic page, or on a
/// page like this one: how much each host, policy or network under it
/// carried. A row narrows it further, until no grouping is left. Narrowed
/// to the bare addresses past a day's cap, it says what they are.
struct TrafficDetailsView: View {
    @State private var model: TrafficLedgerModel
    @State private var opened: TrafficDestination?
    private let title: String

    init(destination: TrafficDestination) {
        _model = State(initialValue: TrafficLedgerModel(
            filter: destination.filter,
            period: destination.period,
            group: destination.group,
        ))
        title = destination.title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.filter.host == TrafficLedgerRow.otherIPs {
                    Text("traffic.details.otherIPsNote \(TrafficLedgerRow.maxIPHosts)")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.horizontal, 4)
                }
                TrafficLedgerSection(model: model) { opened = $0 }
            }
            .padding(16)
            .readableColumn()
        }
        .background(AppTheme.screenBackground)
        .scrollContentBackground(.hidden)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.query) { await model.run() }
        .navigationDestination(item: $opened) { TrafficDetailsView(destination: $0) }
    }
}

/// The traffic ledger's part of a page: period and grouping pickers, the
/// period's sums, and its rows, largest first. The Traffic page shows it
/// under its data usage; a row opens a `TrafficDetailsView` narrowed to it.
struct TrafficLedgerSection: View {
    @Bindable var model: TrafficLedgerModel
    let onOpen: (TrafficDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("traffic.details.period", selection: $model.period) {
                ForEach(TrafficPeriod.allCases, id: \.self) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("traffic.details.period")
            if model.groups.count > 1 {
                Picker("traffic.details.groupBy", selection: $model.group) {
                    ForEach(model.groups, id: \.self) { group in
                        Text(group.title).tag(group)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("traffic.details.groupBy")
            }
            TrafficSummary(report: model.report)
            rows
            Text("traffic.details.footer")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var rows: some View {
        if let report = model.report {
            if report.rows.isEmpty {
                hint(Text("traffic.details.empty"))
                    .accessibilityIdentifier("traffic.details.empty")
            } else {
                rowList(report.rows)
            }
        } else if let error = model.error {
            hint(Text("traffic.details.error \(error)"))
                .accessibilityIdentifier("traffic.details.error")
        }
    }

    /// Lazy: a month can hold thousands of hosts.
    private func rowList(_ rows: [TrafficLedgerRow]) -> some View {
        let group = model.group
        return LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                if row.id != rows.first?.id {
                    Divider().padding(.leading, 56)
                }
                let name = TrafficNames.name(of: row.name, in: group)
                TrafficLedgerRowView(name: name, row: row, action: model.canOpen(row) ? {
                    onOpen(TrafficDestination(
                        filter: model.filter.with(group, row.name),
                        period: model.period,
                        group: group,
                        title: name,
                    ))
                } : nil)
            }
        }
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1),
        )
    }

    private func hint(_ text: Text) -> some View {
        text
            .font(.subheadline)
            .foregroundStyle(AppTheme.mutedText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

/// The period's sums over its rows; the request count goes under them when
/// it does not fit beside them.
private struct TrafficSummary: View {
    let report: TrafficReport?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sums
                Spacer(minLength: 0)
                requests
            }
            VStack(alignment: .leading, spacing: 4) {
                sums
                requests
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("traffic.details.summary")
    }

    private var sums: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TrafficBytes.text(report?.total ?? 0))
                .font(.headline.monospacedDigit())
            TrafficDirections(download: report?.download ?? 0, upload: report?.upload ?? 0)
        }
        .lineLimit(1)
    }

    private var requests: some View {
        Text("traffic.requests \(report?.requests ?? 0)")
            .font(.caption)
            .foregroundStyle(AppTheme.mutedText)
            .lineLimit(1)
    }
}

/// One row: its name, total, requests and directions; a chevron when it
/// opens a page narrowed to it.
private struct TrafficLedgerRowView: View {
    let name: String
    let row: TrafficLedgerRow
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            TrafficAvatar(name: name)
            VStack(alignment: .leading, spacing: 2) {
                // The name shares its line with the total only, so a long
                // one keeps the width the directions would take; it takes a
                // second line before it is cut.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.subheadline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text(TrafficBytes.text(row.total))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                }
                // The directions go under the requests on a narrow screen
                // or with large text rather than cut them short.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        requests
                        Spacer(minLength: 0)
                        TrafficDirections(download: row.download, upload: row.upload)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        requests
                        TrafficDirections(download: row.download, upload: row.upload)
                    }
                }
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("traffic.row.\(row.name.identifierSlug)")
    }

    private var requests: some View {
        Text("traffic.requests \(row.requests)")
            .font(.caption)
            .foregroundStyle(AppTheme.mutedText)
            .lineLimit(1)
    }
}

/// "↓ 1.2 MB  ↑ 300 KB", downloads first, read out by name.
private struct TrafficDirections: View {
    let download: Int64
    let upload: Int64

    var body: some View {
        let down = TrafficBytes.text(download)
        let up = TrafficBytes.text(upload)
        Text(verbatim: "↓ \(down)  ↑ \(up)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppTheme.mutedText)
            .lineLimit(1)
            .accessibilityLabel(
                Text("home.traffic.download") + Text(verbatim: " \(down), ")
                    + Text("home.traffic.upload") + Text(verbatim: " \(up)"),
            )
    }
}

/// A letter on a tinted disc, the tint picked by the name so a row keeps
/// its colour from one read, and one launch, to the next.
private struct TrafficAvatar: View {
    let name: String

    private static let palette = [
        AppTheme.accent, AppTheme.ginger, AppTheme.connected, AppTheme.warning, AppTheme.danger,
    ]

    private var letter: String {
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        let tint = Self.palette[Self.index(of: name)]
        Text(verbatim: letter)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }

    /// Not `hashValue`, which changes with every launch.
    private static func index(of name: String) -> Int {
        let hash = name.unicodeScalars.reduce(UInt32(0)) { $0 &* 31 &+ $1.value }
        return Int(hash % UInt32(palette.count))
    }
}

enum TrafficBytes {
    static func text(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}

/// How a row reads: the ledger's empty and catch-all names spelled out, the
/// network labels in the user's language.
enum TrafficNames {
    static func name(of row: String, in group: TrafficGroup) -> String {
        switch group {
        case .host:
            switch row {
            case "": String(localized: "traffic.details.unknown")
            case TrafficLedgerRow.otherIPs: String(localized: "traffic.details.otherIPs")
            default: row
            }
        case .policy:
            row.isEmpty ? String(localized: "traffic.details.unknown") : row
        case .network:
            network(row)
        }
    }

    private static func network(_ label: String) -> String {
        switch label {
        case TrafficNetwork.wifi: String(localized: "traffic.network.wifi")
        case TrafficNetwork.ethernet: String(localized: "traffic.network.ethernet")
        case TrafficNetwork.cellular: String(localized: "statistics.cellular")
        case "", TrafficNetwork.other: String(localized: "statistics.otherNetworks")
        default: label
        }
    }
}

extension TrafficPeriod {
    var title: LocalizedStringKey {
        switch self {
        case .today: "traffic.tile.today"
        case .thisMonth: "traffic.tile.thisMonth"
        case .lastMonth: "traffic.period.lastMonth"
        }
    }
}

extension TrafficGroup {
    var title: LocalizedStringKey {
        switch self {
        case .host: "traffic.by.host"
        case .policy: "traffic.by.policy"
        case .network: "traffic.by.network"
        }
    }
}
