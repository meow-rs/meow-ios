import Charts
import MeowModels
import SwiftData
import SwiftUI

struct TrafficPage: View {
    @Query(sort: \DailyTraffic.date) private var days: [DailyTraffic]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    totalsCard("Today", totals: today)
                    totalsCard("This Month", totals: month)
                }
                HStack(alignment: .top, spacing: 20) {
                    SpeedChartCard()
                    WeekChartCard(days: lastSevenDays)
                }
            }
            .padding(24)
        }
        .navigationTitle("Traffic")
        .navigationSubtitle("Through the tunnel, on this Mac")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: exportCSV) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(days.isEmpty)
            }
        }
    }

    // MARK: - Totals

    private struct Totals {
        var download: Int64 = 0
        var upload: Int64 = 0
    }

    private var today: Totals {
        let key = DailyTraffic.key(for: .now)
        guard let row = days.first(where: { $0.date == key }) else { return Totals() }
        return Totals(download: row.rxBytes, upload: row.txBytes)
    }

    private var month: Totals {
        let prefix = String(DailyTraffic.key(for: .now).prefix(7))
        return days.filter { $0.date.hasPrefix(prefix) }.reduce(into: Totals()) {
            $0.download += $1.rxBytes
            $0.upload += $1.txBytes
        }
    }

    private func totalsCard(_ title: String, totals: Totals) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title)
            HStack(spacing: 28) {
                MetricView(title: "Download", value: MacFormat.bytes(totals.download), valueSize: 24)
                MetricView(title: "Upload", value: MacFormat.bytes(totals.upload), valueSize: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macCard()
    }

    // MARK: - Week

    private var lastSevenDays: [DayTotals] {
        let calendar = Calendar.current
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        return (0 ..< 7).reversed().compactMap { offset -> DayTotals? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: .now)) else {
                return nil
            }
            let row = byKey[DailyTraffic.key(for: date)]
            return DayTotals(date: date, isToday: offset == 0, download: row?.rxBytes ?? 0, upload: row?.txBytes ?? 0)
        }
    }

    private func exportCSV() {
        var csv = "date,download_bytes,upload_bytes\n"
        for day in days {
            csv += "\(day.date),\(day.rxBytes),\(day.txBytes)\n"
        }
        MacSavePanel.save(Data(csv.utf8), suggestedName: "meow-traffic.csv", contentType: .commaSeparatedText)
    }
}

struct DayTotals: Identifiable {
    var id: Date {
        date
    }

    let date: Date
    let isToday: Bool
    let download: Int64
    let upload: Int64

    var label: String {
        isToday ? "Today" : date.formatted(.dateTime.weekday(.abbreviated))
    }
}

// MARK: - Speed chart

private struct SpeedChartCard: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @State private var hovered: Date?

    var body: some View {
        let samples = appModel.utilityTrafficChart.samples
        let now = samples.last?.timestamp ?? .now
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speed")
                    .font(.headline)
                    .foregroundStyle(MacTheme.ink)
                Spacer()
                legend("Download", value: current.downloadRate, color: MacTheme.download)
                legend("Upload", value: current.uploadRate, color: MacTheme.upload)
            }
            Chart {
                ForEach(samples) { sample in
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Rate", sample.downloadRate),
                    )
                    .foregroundStyle(MacTheme.download.opacity(0.08))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Rate", sample.downloadRate),
                        series: .value("Series", "Download"),
                    )
                    .foregroundStyle(MacTheme.download)
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Rate", sample.uploadRate),
                        series: .value("Series", "Upload"),
                    )
                    .foregroundStyle(MacTheme.upload)
                    .interpolationMethod(.monotone)
                }
                if let sample = hoveredSample(in: samples) {
                    RuleMark(x: .value("Time", sample.timestamp))
                        .foregroundStyle(MacTheme.secondaryInk.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            ChartTooltip(
                                title: "\(max(0, Int(Date().timeIntervalSince(sample.timestamp)))) s ago",
                                rows: [
                                    .init("Download", MacFormat.rate(sample.downloadRate), MacTheme.download),
                                    .init("Upload", MacFormat.rate(sample.uploadRate), MacTheme.upload),
                                ],
                            )
                        }
                }
            }
            .chartXSelection(value: $hovered)
            .chartXScale(domain: now.addingTimeInterval(-60) ... now)
            .chartXAxis {
                AxisMarks(values: [now.addingTimeInterval(-60), now.addingTimeInterval(-30), now]) { value in
                    let date = value.as(Date.self) ?? now
                    // Pin the end labels inside the plot; centred, "now" overflows and is dropped.
                    AxisValueLabel(anchor: axisAnchor(date, now: now)) {
                        Text(axisLabel(date, now: now))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let rate = value.as(Int64.self) {
                            Text(MacFormat.rate(rate))
                        }
                    }
                }
            }
            .frame(height: 220)
            .overlay {
                if samples.isEmpty {
                    Text(controller.isConnected ? "Collecting samples…" : "Not connected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macCard()
    }

    private var current: TrafficSnapshot {
        controller.isConnected ? appModel.ipcBridge.currentTraffic : .init()
    }

    private func hoveredSample(in samples: [TrafficRateSample]) -> TrafficRateSample? {
        guard let hovered else { return nil }
        return samples.min {
            abs($0.timestamp.timeIntervalSince(hovered)) < abs($1.timestamp.timeIntervalSince(hovered))
        }
    }

    private func axisAnchor(_ date: Date, now: Date) -> UnitPoint {
        switch Int(now.timeIntervalSince(date).rounded()) {
        case ...0: .topTrailing
        case 60...: .topLeading
        default: .top
        }
    }

    private func axisLabel(_ date: Date, now: Date) -> String {
        switch Int(now.timeIntervalSince(date).rounded()) {
        case ...0: "now"
        case 60...: "60 s ago"
        case let ago: "\(ago) s"
        }
    }

    private func legend(_ title: String, value: Int64, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 2)
            Text(title).foregroundStyle(MacTheme.secondaryInk)
            Text(MacFormat.rate(value)).fontWeight(.semibold).foregroundStyle(MacTheme.ink).monospacedDigit()
        }
        .font(.caption)
    }
}

// MARK: - Week chart

private struct WeekChartCard: View {
    let days: [DayTotals]
    @State private var showsTable = false
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last 7 Days")
                    .font(.headline)
                    .foregroundStyle(MacTheme.ink)
                Spacer()
                if !showsTable {
                    legendDot("Download", MacTheme.download)
                    legendDot("Upload", MacTheme.upload)
                }
                Picker("View", selection: $showsTable) {
                    Text("Chart").tag(false)
                    Text("Table").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if showsTable {
                table
            } else {
                chart
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macCard()
    }

    private var chart: some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.label), y: .value("Bytes", day.download))
                    .foregroundStyle(MacTheme.download)
                    .position(by: .value("Series", "Download"))
                    .cornerRadius(2)
                BarMark(x: .value("Day", day.label), y: .value("Bytes", day.upload))
                    .foregroundStyle(MacTheme.upload)
                    .position(by: .value("Series", "Upload"))
                    .cornerRadius(2)
            }
            if let hovered, let day = days.first(where: { $0.label == hovered }) {
                RectangleMark(x: .value("Day", day.label))
                    .foregroundStyle(Color.accentColor.opacity(0.06))
                    .zIndex(-1)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                            rows: [
                                .init("Download", MacFormat.bytes(day.download), MacTheme.download),
                                .init("Upload", MacFormat.bytes(day.upload), MacTheme.upload),
                            ],
                        )
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(MacFormat.bytes(bytes))
                    }
                }
            }
        }
        .frame(height: 220)
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Day")
                Text("Download").gridColumnAlignment(.trailing)
                Text("Upload").gridColumnAlignment(.trailing)
                Text("Total").gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacTheme.secondaryInk)
            Divider()
            ForEach(days.reversed()) { day in
                GridRow {
                    Text(day.isToday ? "Today" : day.date.formatted(.dateTime.weekday().month().day()))
                    Text(MacFormat.bytes(day.download))
                    Text(MacFormat.bytes(day.upload))
                    Text(MacFormat.bytes(day.download + day.upload)).fontWeight(.semibold)
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(MacTheme.ink)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
    }

    private func legendDot(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(title).foregroundStyle(MacTheme.secondaryInk)
        }
        .font(.caption)
    }
}

struct ChartTooltip: View {
    struct Row {
        let title: String
        let value: String
        let color: Color

        init(_ title: String, _ value: String, _ color: Color) {
            self.title = title
            self.value = value
            self.color = color
        }
    }

    let title: String
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            ForEach(rows, id: \.title) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 7, height: 7)
                    Text(row.title)
                    Spacer(minLength: 12)
                    Text(row.value).fontWeight(.bold).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.white)
            }
        }
        .padding(10)
        .frame(minWidth: 150)
        .background(Color(light: 0x13293D, dark: 0x2A3846), in: RoundedRectangle(cornerRadius: 8))
    }
}
