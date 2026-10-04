import MeowModels
import SwiftUI

/// Settings › Performance Metrics: the daily MetricKit summaries the app and
/// the tunnel extension saved into `MetricReportStore`. iOS delivers one per
/// process roughly every 24 hours, covering the previous day. The top section
/// rolls the last week up per process (the tunnel's peak memory is the number
/// to watch against its jetsam limit); each daily report opens to its full
/// summary and shares the raw payload.
struct PerformanceMetricsView: View {
    @State private var records: [MetricRecord] = []
    @State private var confirmingDeleteAll = false
    private let store = MetricReportStore()

    var body: some View {
        Form {
            if records.isEmpty {
                ContentUnavailableView(
                    "metrics.empty.title",
                    systemImage: "gauge.with.dots.needle.33percent",
                    description: Text("metrics.empty.description"),
                )
            } else {
                // Tunnel first: its peak memory against the jetsam limit is the
                // number this screen exists for.
                ForEach([MetricSource.tunnel, .app], id: \.self) { source in
                    let recent = lastWeek(source)
                    if !recent.isEmpty {
                        MetricWeekSection(source: source, summaries: recent.map(\.summary))
                    }
                }
                Section {
                    ForEach(records) { record in
                        NavigationLink {
                            MetricDetailView(record: record)
                        } label: {
                            MetricRow(record: record)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            store.delete(records[index])
                        }
                        reload()
                    }
                } header: {
                    Text("metrics.section.daily")
                }
            }
        }
        .readableColumn()
        .navigationTitle("metrics.nav.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                Button("crashReports.button.deleteAll", role: .destructive) {
                    confirmingDeleteAll = true
                }
                .accessibilityIdentifier("metrics.button.deleteAll")
            }
        }
        .confirmationDialog(
            "metrics.deleteAll.title",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible,
        ) {
            Button("crashReports.button.deleteAll", role: .destructive) {
                store.deleteAll()
                reload()
            }
        }
        .onAppear(perform: reload)
    }

    private func lastWeek(_ source: MetricSource) -> [MetricRecord] {
        let cutoff = Date.now.addingTimeInterval(-7 * 86400).timeIntervalSince1970
        return records.filter { $0.source == source && $0.summary.end >= cutoff }
    }

    private func reload() {
        records = store.records()
    }
}

/// Seven-day roll-up for one process: the worst peak memory, the totals for
/// CPU and traffic, and how often the system killed it.
private struct MetricWeekSection: View {
    let source: MetricSource
    let summaries: [MetricSummary]

    var body: some View {
        Section {
            if let peak = summaries.compactMap(\.peakMemoryBytes).max() {
                LabeledContent("metrics.label.peakMemory", value: MetricFormat.bytes(peak))
            }
            if let cpu = sum(\.cpuTimeSeconds) {
                LabeledContent("metrics.label.cpuTime", value: MetricFormat.duration(cpu))
            }
            if let down = sum(\.wifiDownloadBytes, \.cellularDownloadBytes) {
                LabeledContent("metrics.label.download", value: MetricFormat.bytes(down))
            }
            if let up = sum(\.wifiUploadBytes, \.cellularUploadBytes) {
                LabeledContent("metrics.label.upload", value: MetricFormat.bytes(up))
            }
            LabeledContent(
                "metrics.label.memoryLimitExits",
                value: "\(summaries.reduce(0) { $0 + $1.exits(.memoryLimit) })",
            )
            LabeledContent(
                "metrics.label.forcedExits",
                value: "\(summaries.reduce(0) { $0 + $1.abnormalExitCount })",
            )
        } header: {
            Text("\(source.title) · \(String(localized: "metrics.section.lastWeek"))")
        } footer: {
            if source == .tunnel {
                Text("metrics.footer.tunnel")
            }
        }
    }

    /// Sum over the given fields across every summary; nil when none of the
    /// summaries has any of them.
    private func sum(_ fields: KeyPath<MetricSummary, Double?>...) -> Double? {
        let values = summaries.flatMap { summary in fields.compactMap { summary[keyPath: $0] } }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

private struct MetricRow: View {
    let record: MetricRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.summary.endDate, format: .dateTime.year().month().day())
                Spacer()
                Text(record.source.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let summary = record.summary
        return [
            summary.peakMemoryBytes.map {
                String(localized: "metrics.row.peak \(MetricFormat.bytes($0))")
            },
            summary.cpuTimeSeconds.map {
                String(localized: "metrics.row.cpu \(MetricFormat.duration($0))")
            },
            summary.abnormalExitCount > 0
                ? String(localized: "metrics.row.exits \(summary.abnormalExitCount)")
                : nil,
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
    }
}

private struct MetricDetailView: View {
    let record: MetricRecord

    private var summary: MetricSummary {
        record.summary
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("crashReports.detail.process", value: summary.bundleIdentifier ?? record.source.title)
                if let version = summary.appVersion {
                    LabeledContent(
                        "crashReports.detail.version",
                        value: [version, summary.appBuildVersion.map { "(\($0))" }]
                            .compactMap(\.self).joined(separator: " "),
                    )
                }
                if let os = summary.osVersion {
                    LabeledContent("crashReports.detail.os", value: os)
                }
                LabeledContent("metrics.label.period") {
                    Text(summary.beginDate ... max(summary.beginDate, summary.endDate))
                }
            }
            Section("metrics.section.resources") {
                row("metrics.label.peakMemory", summary.peakMemoryBytes.map(MetricFormat.bytes))
                row("metrics.label.suspendedMemory", summary.averageSuspendedMemoryBytes.map(MetricFormat.bytes))
                row("metrics.label.cpuTime", summary.cpuTimeSeconds.map(MetricFormat.duration))
                row("metrics.label.foreground", summary.foregroundTimeSeconds.map(MetricFormat.duration))
                row("metrics.label.background", summary.backgroundTimeSeconds.map(MetricFormat.duration))
                row("metrics.label.diskWrites", summary.logicalWritesBytes.map(MetricFormat.bytes))
                row("metrics.label.launch", summary.launchMedianSeconds.map(MetricFormat.duration))
                row("metrics.label.hangs", summary.hangCount.map { "\($0)" })
            }
            Section("metrics.section.network") {
                row("metrics.label.wifiDown", summary.wifiDownloadBytes.map(MetricFormat.bytes))
                row("metrics.label.wifiUp", summary.wifiUploadBytes.map(MetricFormat.bytes))
                row("metrics.label.cellDown", summary.cellularDownloadBytes.map(MetricFormat.bytes))
                row("metrics.label.cellUp", summary.cellularUploadBytes.map(MetricFormat.bytes))
            }
            Section {
                let reasons = MetricExitReason.allCases.filter { summary.exits($0) > 0 }
                if reasons.isEmpty {
                    Text("metrics.exits.none")
                        .foregroundStyle(.secondary)
                }
                ForEach(reasons, id: \.self) { reason in
                    LabeledContent(reason.title, value: "\(summary.exits(reason))")
                }
            } header: {
                Text("metrics.section.exits")
            }
        }
        .readableColumn()
        .navigationTitle(Text(summary.endDate, format: .dateTime.month().day()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: record.url) {
                Label("crashReports.button.share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("metrics.button.share")
        }
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value {
            LabeledContent(title, value: value)
        }
    }
}

private enum MetricFormat {
    static func bytes(_ value: Double) -> String {
        Measurement(value: value, unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .memory))
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 {
            return Duration.milliseconds(Int64(seconds * 1000)).formatted(.units(allowed: [.milliseconds]))
        }
        return Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

extension MetricSource {
    var title: String {
        switch self {
        case .app: String(localized: "metrics.source.app")
        case .tunnel: String(localized: "metrics.source.tunnel")
        }
    }
}

extension MetricExitReason {
    var title: String {
        switch self {
        case .normal: String(localized: "metrics.exit.normal")
        case .abnormal: String(localized: "metrics.exit.abnormal")
        case .memoryLimit: String(localized: "metrics.exit.memoryLimit")
        case .memoryPressure: String(localized: "metrics.exit.memoryPressure")
        case .watchdog: String(localized: "metrics.exit.watchdog")
        case .cpuLimit: String(localized: "metrics.exit.cpuLimit")
        case .badAccess: String(localized: "metrics.exit.badAccess")
        case .illegalInstruction: String(localized: "metrics.exit.illegalInstruction")
        case .lockedFile: String(localized: "metrics.exit.lockedFile")
        case .taskAssertionTimeout: String(localized: "metrics.exit.taskAssertionTimeout")
        }
    }
}
